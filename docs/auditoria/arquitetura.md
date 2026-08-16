# Auditoria técnica — arquitetura, padrões de aplicação e modernização

Arquivos auditados (não alterados):

- `dotnet-code-review/designpatterns/references/arquitetura.md` (ARQ)
- `dotnet-code-review/designpatterns/references/catalogo-patterns.md`, seção "Padrões de aplicação" (CAT)
- `dotnet-code-review/designpatterns-legacy/references/modernizacao.md` (MOD)

Lidos como contexto, para não acusar como lacuna o que já existe em outro arquivo:
`designpatterns/SKILL.md`, `dotnet-moderno.md`, `designpatterns-legacy/references/restricoes-versoes.md`.

## Os cinco achados mais graves

1. **(a13) MOD degrau 3 é impossível no projeto que mais importa.** Web application `System.Web`
   (Web Forms / MVC 5 / Web API 2) não converte para csproj SDK-style de forma suportada. A escada
   apresenta o degrau como geral.
2. **(c1) MOD não menciona `Microsoft.AspNetCore.SystemWebAdapters`**, que é a via oficial da
   Microsoft para exatamente os dois problemas que o próprio arquivo declara serem os que mais
   atrasam o projeto (sessão e autenticação compartilhadas). Sem isso o arquivo entrega um beco
   sem saída onde existe caminho suportado.
3. **(b1/b2) A checagem "de maior retorno do review inteiro" tem falso negativo estrutural.**
   `global using` e `PackageReference` injetada por `Directory.Build.props` fazem o domínio
   compilar contra EF Core sem uma linha de `using` no arquivo nem no `.csproj` do domínio.
4. **(c4) Fronteira de transação é citada três vezes e nunca especificada.** Falta atomicidade do
   `SaveChanges`, conflito `EnableRetryOnFailure` × `BeginTransaction`, um-agregado-por-transação,
   concorrência otimista e outbox na mesma transação.
5. **(d2) A linha de Vertical Slice dá conselho ruim.** "Regra compartilhada entre slices" não é
   motivo para abandonar VSA; é motivo para extrair domínio mantendo os slices.

---

# (a) ERROS FACTUAIS

## arquitetura.md

### a1 — Interfaces "vivem na Application" contradiz DDD e a própria tabela de escolha
**Trecho** (ARQ:56): "Casos de uso, orquestração, contratos das dependências externas (as
interfaces vivem aqui, as implementações não)."

**Problema.** Dito como regra única, produz achado falso ao revisar código DDD correto. Em DDD +
Clean, `IOrderRepository` é conceito de domínio e pertence ao **Domain** (é o layout do template
Ardalis.CleanArchitecture); portas de caso de uso (`IEmailSender`, `IPaymentGateway`,
`IApplicationDbContext`) pertencem à **Application** (layout Jason Taylor). O arquivo recomenda DDD
na tabela de escolha (ARQ:82) e depois marcaria como violação o lugar canônico do repositório.

**Correção.** Substituir por: "Contratos das dependências externas. Regra: **repositório de
agregado pertence ao Domain** (é vocabulário de domínio); **porta de infraestrutura** (e-mail,
pagamento, storage, relógio, fila) pertence à Application. O achado não é 'a interface está na
camada X', é **a interface e a implementação no mesmo assembly quando o consumidor precisa não
depender do provedor**, e **inconsistência**: metade em Domain, metade em Application sem critério."

### a2 — `[Table]`/`[Column]` no domínio: justificativa errada, severidade errada
**Trecho** (ARQ:36): "Atributo de mapeamento (`[Table]`, `[Column]`) na entidade de domínio |
Persistência vazando para o modelo. Use Fluent API na Infrastructure"

**Problema.** `[Table]`, `[Column]`, `[Key]`, `[ForeignKey]`, `[NotMapped]` vêm de
`System.ComponentModel.DataAnnotations.Schema`, que está na BCL. **Não criam dependência de EF
Core.** É questão de pureza de modelo, não de acoplamento a ORM — o domínio continua compilando e
testando sem o EF instalado. A tabela está sob o título "Detecção mecânica de violações" e este
item não é violação de dependência.

**Correção.** Rebaixar para 🟡 com a justificativa correta ("acoplamento *conceitual* ao esquema,
sem acoplamento de assembly") e criar linha separada 🟠 para os atributos que **realmente** trazem
o pacote `Microsoft.EntityFrameworkCore`: `[Owned]`, `[Keyless]`, `[Index]`, `[Precision]`,
`[Comment]`, `[DeleteBehavior]`, `[EntityTypeConfiguration]`. Esses sim provam acoplamento ao ORM.

### a3 — "Interface pertence a quem consome" descreve configuração que o compilador já impede
**Trecho** (ARQ:42): "Interface e implementação no mesmo projeto de infraestrutura, consumidas pelo
domínio | A abstração está do lado errado. Interface pertence a quem consome"

**Problema.** Se o domínio consome uma interface declarada em Infrastructure, então
`Domain.csproj → Infrastructure.csproj` existe, e isso já é a linha 1 da mesma tabela (ARQ:34). A
linha é redundante como escrita e, pior, generalizada ("interface pertence a quem consome") gera
falso positivo: abstrações **internas da infraestrutura** (`IBlobClientFactory`,
`IConnectionStringProvider`, `ISqlRetryPolicy`) usadas só dentro de Infrastructure estão corretas
ao lado da implementação. O princípio é Separated Interface, e ele se aplica quando o consumidor
não pode depender do pacote do provedor — não sempre.

**Correção.** Trocar por sinal detectável e não redundante: "**Assinatura de porta na Application
expondo tipo de infraestrutura** (`Task<SqlConnection>`, `IQueryable<T>`, `HttpResponseMessage`,
`BlobClient`, DTO de SDK). A interface está na camada certa e vaza o provedor pelo tipo de retorno,
que o compilador não impede." E acrescentar isenção explícita: "abstração usada apenas dentro da
Infrastructure não é violação."

### a4 — A camada da fronteira de transação é afirmada sem o único ponto que muda a decisão
**Trecho** (ARQ:60): "Fronteira de transação normalmente pertence aqui."

**Problema.** Correto e insuficiente ao ponto de virar erro na prática. Falta o fato que decide a
maioria dos casos: **`SaveChangesAsync` já é atômico** (o EF Core envolve todas as alterações de uma
chamada numa transação, quando o provedor suporta). Sem isso o revisor recomenda
`BeginTransaction`/`TransactionScope` onde não é necessário — e onde `EnableRetryOnFailure` está
ligado, essa recomendação **lança em runtime** (ver c4).

**Correção.** Ver o bloco de substituição completo em **c4**.

### a5 — O smell "transação difusa" tem exceção obrigatória em DDD e em outbox
**Trecho** (ARQ:100): "`SaveChanges` chamado em vários pontos de um mesmo fluxo | Um commit por
unidade de trabalho, na fronteira do caso de uso"

**Problema.** Aplicado sem exceção, o revisor marca como defeito dois desenhos corretos:
(1) DDD prescreve **uma transação por agregado**, então dois `SaveChanges` para dois agregados com
consistência eventual entre eles é deliberado, não difuso; (2) o outbox exige que o insert do evento
esteja **na mesma** chamada de `SaveChanges` da alteração de estado — o que é uma restrição sobre
*qual* commit, não sobre *quantos*.

**Correção.** "Sinal: dois ou mais `SaveChanges` no mesmo caso de uso **sem** transação explícita —
falha no segundo deixa o primeiro commitado. Correção: um commit por unidade de trabalho; se dois
são inevitáveis, transação explícita via `CreateExecutionStrategy().ExecuteAsync(...)`. **Isenções:**
um commit por agregado com consistência eventual declarada entre eles; insert de outbox no mesmo
`SaveChanges` do estado."

### a6 — Falta dizer que o composition root pode referenciar tudo
**Trecho** (ARQ:65): "Depende de Application e Domain, nunca o contrário."

**Problema.** Verdadeiro para a camada, e a omissão gera o falso positivo mais frequente de review
de Clean Architecture: `Api.csproj → Infrastructure.csproj` é apontado como violação. Não é. O
composition root precisa conhecer as implementações para registrá-las; evitar essa referência com
scan de assembly por reflexão troca erro de compilação por falha em runtime, que é pior.

**Correção.** Acrescentar: "A referência `Api → Infrastructure` **é esperada**: composition root
conhece as implementações por definição. Se o time a evita com `Assembly.Load`/scan por convenção,
aponte o trade-off (erro de compilação virou erro de runtime). O que a Api não deve fazer é *usar*
tipos de Infrastructure fora do `Program.cs`/`ServiceCollectionExtensions` — e esse é o sinal
detectável de verdade."

## catalogo-patterns.md — Padrões de aplicação

### a7 — A validação de escopo do container promete detecção que ela não tem
**Trecho** (CAT:267): "A validação de escopo do container detecta isso na inicialização em
Development, então nunca desligue."

**Problema.** Três imprecisões que juntas dão falsa segurança:
1. São **dois** mecanismos com escopos diferentes: `ValidateOnBuild` valida o grafo no build do
   host; `ValidateScopes` falha em runtime ao resolver `Scoped` a partir do provider raiz.
2. Nenhum dos dois vê dentro de **factory delegates**:
   `AddSingleton<IFoo>(sp => new Foo(sp.GetRequiredService<IBar>()))` com `IBar` scoped passa a
   validação e é captive dependency. Isso é justamente a forma recomendada em CAT:142 para compor
   decorators, então o arquivo recomenda o padrão que cega a própria checagem.
3. Ambos são ligados por padrão **apenas** em `Development`. Em Production estão desligados, então a
   afirmação "detecta na inicialização" não vale para o ambiente onde o defeito custa.

**Correção.** "`ValidateOnBuild` (grafo, no build do host) e `ValidateScopes` (resolução de `Scoped`
pela raiz) são ligados por padrão **somente em Development** — ligue-os explicitamente em CI e
Staging. Limite importante: nenhum dos dois inspeciona o corpo de um factory delegate
(`AddSingleton(sp => ...)`), nem detecta Service Locator. Registro por delegate com
`GetRequiredService` de algo `Scoped` continua sendo achado manual 🔴."

### a8 — `IOptionsSnapshot<T>` é Scoped, e o arquivo não liga isso ao próprio aviso de captive dependency
**Trecho** (CAT:275): "`IOptionsSnapshot<T>` recarrega por escopo; `IOptionsMonitor<T>` recarrega na
hora com callback (singletons que reagem a mudança)."

**Problema.** Factualmente correto e incompleto no ponto que causa o bug: `IOptionsSnapshot<T>` é
registrado como **Scoped**, `IOptions<T>` e `IOptionsMonitor<T>` como **Singleton**. Injetar
`IOptionsSnapshot<T>` em singleton, hosted service ou `DelegatingHandler` (que é transient mas vive
no handler pipeline) é exatamente a captive dependency que CAT:267 acabou de proibir — e é o bug
número um de Options em .NET. O parêntese "(singletons que reagem a mudança)" insinua a regra sem
enunciá-la.

**Correção.** Acrescentar linha: "**Lifetime:** `IOptions<T>` e `IOptionsMonitor<T>` são Singleton;
`IOptionsSnapshot<T>` é **Scoped**. Logo, `IOptionsSnapshot<T>` em singleton / `BackgroundService` /
`DelegatingHandler` é captive dependency 🔴 — nesses casos use `IOptionsMonitor<T>`."

### a9 — Specification: "sem risco de divergirem" é falso como descrito, e falta o modo de falha real
**Trecho** (CAT:308): "usá-la nos dois mundos, no banco via `Expression<Func<T,bool>>` e em memória
via `IsSatisfiedBy`, sem risco de divergirem."

**Problema.** Duas afirmações incorretas:
1. Se `IsSatisfiedBy` é uma implementação **separada** da `Expression`, elas divergem exatamente
   como duas cópias de qualquer regra. A garantia só existe se `IsSatisfiedBy` for
   `Expression.Compile()` invocada — uma fonte, dois consumos.
2. Falta o modo de falha que domina a prática: **spec composta com `Func<T,bool>` em vez de
   `Expression<Func<T,bool>>` faz o `Where` cair em LINQ-to-Objects e traz a tabela inteira**. E
   `Expression` que chama método próprio (inclusive `IsSatisfiedBy`) **não traduz**, e desde o
   EF Core 3.0 isso **lança** em vez de avaliar no cliente silenciosamente.

**Correção.** "Ganho real: dar nome de negócio à regra. Garantia de não divergir só existe com uma
fonte única: `Expression<Func<T,bool>>` como verdade e `IsSatisfiedBy` implementado como
`_expression.Compile()(entity)`. **Achados de review:** spec exposta como `Func<T,bool>` (o `Where`
sai do banco e traz a tabela — 🔴); spec chamando método próprio dentro da expressão (não traduz e
lança no EF Core 3.0+); spec carregando strings de `Include`. Pronto no ecossistema:
`Ardalis.Specification`."

### a10 — CQRS: falta desfazer a confusão que mais gera conselho ruim
**Trecho** (CAT:314): "Desfaça a confusão: CQRS não é event sourcing e não exige bancos separados."

**Problema.** As duas confusões desfeitas estão certas, e falta a terceira, que é a que aparece em
review: **CQS ≠ CQRS**. O dogma "command não retorna dado" é CQS; em CQRS aplicado a HTTP, devolver
o id do recurso criado é normal e necessário (`201 Created` + `Location`). Revisores citando CQRS
exigem `void` em handlers de escrita e forçam um segundo round-trip.

**Correção.** Acrescentar: "Terceira confusão: **CQS não é CQRS**. 'Command não retorna valor' é
CQS. Um command handler devolver o id gerado (ou um `Result<Guid>`) é correto e necessário para
`201 Created`. Não aponte isso como violação."

### a11 — "Result é muito mais rápido que exceção" convida à decisão por motivo errado
**Trecho** (CAT:280): "**Ganhos:** ... muito mais rápido que exceção"

**Problema.** Verdadeiro em ordem de grandeza (exceção custa dezenas de microssegundos, retorno
custa nada) e irrelevante abaixo de alguma frequência. Como o arquivo já tem uma regra de decisão
semântica excelente na linha anterior ("fluxo normal é retorno, defeito é exceção"), pôr custo no
mesmo nível empurra Result para perto de "otimização", que contradiz a política anti-otimização-sem-
medição de `dotnet-moderno.md`:224.

**Correção.** "**Ganhos:** a assinatura documenta que pode falhar; múltiplos erros de validação em
um retorno; custo desprezível em caminho de altíssima frequência (o custo de exceção só importa
acima de milhares por segundo — **não use performance como argumento principal**)."

### a12 — `DbContext` "já é Repository" precisa da ressalva que justifica o repositório em DDD
**Trecho** (CAT:286): "o `DbContext` do EF Core **já é** Repository (`DbSet<T>`) e **já é** Unit of
Work (`SaveChangesAsync`)."

**Problema.** A frase é a mais valiosa da seção e, sem ressalva, derruba o caso legítimo listado
duas linhas abaixo. `DbSet<T>` é um *generic repository sobre `IQueryable`*: ele não dá o que o
repositório de DDD existe para dar — **carga de agregado completo** (impedir `Order` sem `OrderLines`
e portanto invariante avaliada sobre estado parcial) e **manter `IQueryable` fora do domínio**.

**Correção.** Acrescentar: "Ressalva: `DbSet<T>` é generic repository sobre `IQueryable`. Ele não
garante **carga de agregado completo** nem impede `IQueryable` de circular. É por isso que o
repositório de agregado em DDD continua valendo: o ganho é 'não existe caminho para carregar meio
agregado', não 'abstrair o EF'."

## modernizacao.md

### a13 — Degrau 3 é inaplicável ao projeto web `System.Web`
**Trecho** (MOD:19): "**Degrau 3, converter o `.csproj` para o formato SDK.** Ainda com alvo
`net48`. ... Cuidado com `AssemblyInfo.cs` duplicado e com arquivos de conteúdo que precisam de
declaração explícita."

**Problema.** O degrau é apresentado como geral e **não é possível de forma suportada no projeto que
concentra o legado**: web application `System.Web` (Web Forms, MVC 5, Web API 2) depende de
`Microsoft.WebApplication.targets` e do sistema de projeto web do Visual Studio, que o SDK-style não
suporta — quebram publish/Web Deploy, designers, `.aspx`/`.ascx` code-behind e a compilação do
`Global.asax`. Existe o SDK comunitário `MSBuild.SDK.SystemWeb`, que não é suportado pela Microsoft.
Além disso, "permite `<LangVersion>`" está errado: `<LangVersion>` funciona no csproj antigo também.

**Correção.** "**Degrau 3, converter para SDK-style — bibliotecas de classe primeiro.** Ainda com
alvo `net48`. Elimina a lista manual de arquivos e habilita multi-targeting.
**Restrição que precisa ser dita:** o projeto **web** `System.Web` (Web Forms, MVC 5, Web API 2)
**não** converte de forma suportada — depende de `Microsoft.WebApplication.targets`. Converta as
class libraries e deixe o projeto web no formato antigo até o degrau 6. (`MSBuild.SDK.SystemWeb`
existe e não é suportado pela Microsoft; se o time usar, é decisão consciente.) Cuidado com
`AssemblyInfo.cs` duplicado (`<GenerateAssemblyInfo>false</GenerateAssemblyInfo>`) e com arquivos
de conteúdo. Nota: `<LangVersion>` já funciona no formato antigo — não é motivo para converter."

### a14 — Degrau 4 recomenda `netstandard2.0` onde a orientação atual é multi-target
**Trecho** (MOD:21): "**Degrau 4, extrair a regra de negócio para bibliotecas `netstandard2.0`.**"

**Problema.** Funciona, e é a escolha inferior hoje. `netstandard2.0` congela a superfície de API em
2017: sem `Span<T>`/`Memory<T>` sem pacote, sem `IAsyncEnumerable` sem
`Microsoft.Bcl.AsyncInterfaces`, sem `DateOnly`/`TimeOnly`, sem `System.Text.Json` in-box, e as ref
assemblies **não têm anotação de nullability** — habilitar NRT na biblioteca rende resultado
"oblivious" e pouco valor. `netstandard` deixou de ser o alvo recomendado para código novo. A
alternativa correta é **multi-target** `<TargetFrameworks>net48;net8.0</TargetFrameworks>`: o lado
moderno usa API moderna, o lado antigo compila com `#if NETFRAMEWORK`, e a mesma biblioteca serve
aos dois hosts do Strangler Fig.

**Bloqueador factual omitido:** **EF6 não pode entrar em `netstandard2.0`.** `EntityFramework` 6.4
tem alvos `net45` e **`netstandard2.1`** — e `net48` só consome até `netstandard2.0`. Ou seja: se a
regra a extrair toca `DbContext`/entidades do EF6, o degrau 4 como escrito é impossível, e o arquivo
não avisa.

**Correção.** "**Degrau 4, extrair a regra de negócio para biblioteca compartilhada.** Prefira
**multi-target** (`<TargetFrameworks>net48;net8.0</TargetFrameworks>`) a `netstandard2.0`:
`netstandard2.0` congela a API em 2017 (sem `Span`, sem `IAsyncEnumerable` sem
`Microsoft.Bcl.AsyncInterfaces`, sem `DateOnly`, BCL sem anotação de nullability) e deixou de ser o
alvo recomendado. Use `netstandard2.0` só se a biblioteca precisar ser consumida por algo que você
não controla. O que impede uma classe de sair: `System.Web`, `HttpContext.Current`,
`ConfigurationManager` (há pacote `System.Configuration.ConfigurationManager`, mas seções
customizadas não vão), `System.Drawing` e **EF6** — `EntityFramework` 6.4 tem alvos `net45` e
`netstandard2.1`, e `net48` só alcança `netstandard2.0`, então **regra acoplada a EF6 não cabe em
`netstandard2.0`**: multi-target resolve, ou a regra sai de trás do `DbContext` primeiro."

### a15 — API Portability Analyzer está descontinuado
**Trecho** (MOD:74): "rode o **.NET Upgrade Assistant** e o **API Portability Analyzer** para
produzir a lista real de incompatibilidades."

**Problema.** O .NET Portability Analyzer (ApiPort) foi arquivado e não é mais mantido; sua função
foi absorvida pelo .NET Upgrade Assistant. Recomendar ferramenta morta num arquivo cujo tema é
credibilidade de estimativa é caro.

**Correção.** "rode o **.NET Upgrade Assistant** (extensão do VS e CLI; inclui a análise que era do
Portability Analyzer, hoje arquivado) e, depois de compilar no alvo novo, ligue o
**Platform Compatibility Analyzer** (CA1416) para pegar o que compila e falha só em runtime por ser
Windows-only."

### a16 — `System.Drawing.Common` não foi removido: ficou Windows-only
**Trecho** (MOD:64): "| **`System.Drawing.Common`** | `ImageSharp`, `SkiaSharp` |" sob o título "O
que simplesmente não vem junto para o .NET moderno".

**Problema.** Desde .NET 7 `System.Drawing.Common` é **suportado apenas no Windows** (lança
`PlatformNotSupportedException` em Linux/macOS, controlável por
`System.Drawing.EnableUnixSupport` até ser removido). Não foi removido. A diferença é de custo real:
se o destino é Windows (IIS ou container Windows), **não é bloqueador**, e a recomendação de trocar
por ImageSharp (que tem licença comercial acima de certo uso) ou SkiaSharp é trabalho evitável.

**Correção.** "| **`System.Drawing.Common`** | Continua funcionando **no Windows**. Só é bloqueador
se o destino for Linux/container Linux — aí `SkiaSharp` ou `ImageSharp` (verifique a licença do
ImageSharp). Decida junto com o SO de destino, não antes. |"

### a17 — `AppDomain` tem substituto para o caso de plugin
**Trecho** (MOD:62): "| **Remoting, AppDomains** | Sem equivalente. Isolar por processo |"

**Problema.** Correto para isolamento de **segurança** e para Remoting. Errado para o uso mais comum
de `AppDomain` em linha de negócio, que é **carregar e descarregar plugins/assemblies**: o
substituto é `AssemblyLoadContext` colecionável (`isCollectible: true`), que carrega e descarrega
sem processo separado. "Isolar por processo" para esse caso é ordens de magnitude mais caro do que a
resposta certa.

**Correção.** "| **Remoting** | Sem equivalente. Contrato explícito: HTTP/gRPC, ou fila |
**`AppDomain` para plugin/unload** | `AssemblyLoadContext` colecionável (`isCollectible: true`) |
**`AppDomain` para isolamento de segurança/CAS** | Sem equivalente. Isolar por processo |"

### a18 — Blocos ausentes na tabela de bloqueadores (todos são achados de campo frequentes)
**Trecho** (MOD:57-72): a tabela "Bloqueadores conhecidos".

**Correção — acrescentar linhas:**

| Bloqueador | Alternativa |
|---|---|
| **`TransactionScope` promovido a distribuído (MSDTC)** | Não existe em .NET Core a .NET 6; em **.NET 7+ só no Windows**. Se dois recursos são inscritos na mesma `TransactionScope`, o código lança na migração. Redesenhar para transação local + outbox/compensação |
| **ASMX (`System.Web.Services`) servidor** | Sem caminho. Reescrever como Web API ou gRPC. Cliente sobrevive via `dotnet-svcutil` |
| **WIF / `System.IdentityModel` (WS-Federation, SAML)** | `Microsoft.IdentityModel.*` + OIDC. Frequente em legado corporativo e sempre subestimado |
| **`System.Data.SqlClient`** | `Microsoft.Data.SqlClient`. **Atenção:** a partir da 4.0 o default de `Encrypt` virou `true`, então conexão para servidor sem certificado válido passa a falhar. É o item que mais quebra "migração que compilou" |
| **Globalização NLS → ICU** | .NET 5+ usa ICU no Windows: ordenação, `Compare`, `ToUpper`/`ToLower` e `StringComparison.CurrentCulture` **mudam de resultado**. Se houver comparação de string com semântica de negócio, é risco silencioso. `InvariantGlobalization` ou fixar `StringComparison.Ordinal` no que é identificador |
| **EF6 com EDMX** | (corrigir a linha existente) EF6 Code First **roda em .NET moderno** (EF6.3+, provedor SQL Server), então EF6 em si **não é bloqueador**. EDMX é: não é suportado fora do .NET Framework. Ordem: EDMX → EF6 Code First (ainda em `net48`) → decidir depois se vale ir para EF Core |

### a19 — A ordem de migração de rotas contradiz o próprio alerta do arquivo
**Trecho** (MOD:45): "5. Autenticação e sessão, que costumam ser o último e o mais delicado." versus
MOD:49: "Cookie de autenticação compartilhado ... **Planeje isso primeiro**."

**Problema.** As duas frases dizem coisas opostas e a segunda está certa. Autenticação não é uma
rota que se migra por último: é **pré-requisito de qualquer rota autenticada**. Se não há
interoperabilidade de identidade, o degrau 6 para no primeiro endpoint que exige login, ou seja,
imediatamente. O que se migra por último é a **emissão** do login (a tela e o fluxo), não a
capacidade de reconhecê-lo.

**Correção.** "Ordem de migração das rotas, do menor risco para o maior:
0. **Pré-requisito, não etapa: interoperabilidade de identidade.** Antes da primeira rota
   autenticada, as duas aplicações precisam reconhecer o mesmo login (ver seção abaixo). Sem isso o
   projeto para na primeira rota real.
1. Conteúdo estático e endpoints de diagnóstico.
2. Endpoints somente leitura, sem estado de sessão.
3. Endpoints novos, que nascem direto no sistema novo.
4. Escritas idempotentes, ou com chave de idempotência introduzida junto.
5. Fluxos transacionais complexos.
6. **Por último a emissão do login** (tela, fluxo, recuperação de senha) — o reconhecimento do login
   já tinha que estar resolvido no passo 0."

### a20 — "Sem alteração de código" no degrau 1 e o custo real que aparece é binding redirect
**Trecho** (MOD:15): "**Degrau 1, subir o target framework para `net472` ou `net48`.** Geralmente
sem alteração de código."

**Problema.** A frase é verdadeira sobre *código* e esconde onde o degrau realmente consome tempo:
consumir pacotes `netstandard2.0` em `net4x` exige `<AutoGenerateBindingRedirects>` e, em aplicação
web, entradas manuais de `<bindingRedirect>` no `web.config` — os conflitos clássicos são
`System.Runtime`, `System.Net.Http` e `System.ValueTuple`, com `FileLoadException` em runtime, não em
compilação. Isso também inverte a ordem sugerida: o degrau 2 (`PackageReference`, que gera os
redirects automaticamente) é o que faz a promessa do degrau 1 ser verdade.

**Correção.** Acrescentar ao degrau 1: "Sem alteração de **código**, mas conte o custo de
**binding redirects**: consumir `netstandard2.0` em `net4x` costuma exigir
`<AutoGenerateBindingRedirects>true</AutoGenerateBindingRedirects>` e entradas manuais no
`web.config` (`System.Runtime`, `System.Net.Http`, `System.ValueTuple`), e a falha aparece como
`FileLoadException` em runtime. Por isso, na prática **faça o degrau 2 junto**: `PackageReference`
gera os redirects. Verifique também a lista de retargeting changes do .NET Framework, porque
`net461 → net472` muda defaults de TLS e de `HttpClientHandler`."

### a21 — `packages.config → PackageReference`: falta o modo de falha mais comum em app web
**Trecho** (MOD:17): "O Visual Studio tem migração automática, mas verifique pacotes com
`install.ps1`, que não funcionam em `PackageReference`."

**Problema.** `install.ps1` está certo e é o menos frequente. Os que quebram app MVC 5 de verdade:
(1) **arquivos de `content/` não são copiados** em `PackageReference` (pacotes que entregavam
`Scripts/`, `Content/`, views — jQuery, bootstrap, `Microsoft.jQuery.Unobtrusive.Validation` — param
de materializar arquivos); (2) **transformações de config** (`web.config.transform`,
`web.config.install.xdt`) não rodam; (3) `PackageReference` promove dependências transitivas a
resolução por grafo, então versões antes fixadas por `packages.config` mudam silenciosamente.

**Correção.** "O Visual Studio tem migração automática. Verifique, em ordem de frequência:
**arquivos de `content/`**, que `PackageReference` não copia (pacotes de front-end antigos param de
materializar `Scripts/`/`Content/` — os arquivos precisam entrar no repositório);
**transformações de `web.config`** (`.transform`/`.install.xdt`), que não rodam mais; **resolução
transitiva**, que passa a escolher a maior versão do grafo e pode mudar dependência que estava
fixada; e **`install.ps1`**, que não é executado."

---

# (b) HEURÍSTICAS DE DETECÇÃO FRACAS

### b1 — Ler o `.csproj` do domínio não prova ausência de acoplamento (falso negativo grave)
**Trecho** (ARQ:20): "**Leia os `.csproj` primeiro.** As referências entre projetos revelam a
arquitetura real"

**Quatro furos, todos comuns em solution .NET moderna:**
1. **`Directory.Build.props` / `Directory.Packages.props`** podem injetar `PackageReference` em
   **todos** os projetos. `Domain.csproj` fica limpo e o domínio compila contra EF Core.
2. **Acoplamento transitivo:** `Domain → Shared` e `Shared → EF Core`. Ler `Domain.csproj` não vê.
   O que importa é o **fecho transitivo**.
3. **`ReferenceOutputAssembly="false"`** existe para ordem de build: um
   `Domain → Infrastructure` com esse atributo **não** é dependência de código, e a linha ARQ:34
   marcaria falso positivo.
4. **`PrivateAssets="all"`** / pacote de analyzer aparece como `PackageReference` e não é
   acoplamento de runtime.

**Correção.** Substituir o passo 1 por: "**Leia o grafo de dependências, não um `.csproj`.**
Inclua: `Directory.Build.props` e `Directory.Packages.props` (podem injetar `PackageReference` em
todos os projetos), `GlobalUsings.cs` e `<ImplicitUsings>`, e o **fecho transitivo** de
`ProjectReference` (o vazamento costuma vir via `Shared`/`Common`). Ignore `PackageReference` com
`PrivateAssets="all"` (analyzer) e `ProjectReference` com `ReferenceOutputAssembly="false"` (só
ordem de build), que não são acoplamento de código. **Regra mecânica melhor que grep de `using`:
`Domain.csproj` deve ter zero `PackageReference` não-analyzer.** É binário, é rápido, e não tem
falso negativo por `global using`."

### b2 — Grep de `using Microsoft.EntityFrameworkCore` é derrotado por `global using`
**Trecho** (ARQ:22): "**Verifique os `using` do domínio.** É a checagem de maior retorno do review
inteiro: um `using Microsoft.EntityFrameworkCore` num arquivo de domínio prova vazamento de
infraestrutura."

**Falsos negativos.**
1. `global using Microsoft.EntityFrameworkCore;` num `GlobalUsings.cs` (ou via
   `<Using Include="..."/>` em `Directory.Build.props`) faz o arquivo de domínio usar `DbContext`
   **sem nenhuma linha de `using`**. Como esta é declaradamente a checagem de maior retorno, o furo
   é estrutural, não marginal.
2. Nome totalmente qualificado inline (`Microsoft.EntityFrameworkCore.DbContext`) não casa com o
   padrão `using ...`.
3. A lista de namespaces é curta demais. Vazam também: `Microsoft.Data.SqlClient`, `Dapper`,
   `MongoDB.Driver`, `StackExchange.Redis`, `Azure.*`, `AWSSDK.*`, `Newtonsoft.Json` /
   `System.Text.Json.Serialization` (atributo de serialização em entidade),
   `Microsoft.Extensions.DependencyInjection`, `Microsoft.Extensions.Logging` (`ILogger<T>` em
   entidade), `AutoMapper`, `MediatR`, `Refit`, `Grpc.Net.Client`, `Quartz`, `Hangfire`.

**Falsos positivos.** Arquivos que estão na pasta do domínio e não são domínio:
`Migrations/`, `*.g.cs`/`*.Designer.cs`, `obj/`, projeto de teste, e o caso de time que aceitou
`[Owned]` para mapear value object (decisão consciente, não vazamento acidental).

**Correção.** "**Verifique o acoplamento do domínio em duas passadas.** (1) `PackageReference` do
`Domain.csproj` **mais** o que `Directory.Build.props`/`Directory.Packages.props` injetam — o
resultado esperado é zero pacote de infraestrutura; essa passada não tem falso negativo. (2) `using`
por arquivo, **incluindo `GlobalUsings.cs` e `<Using Include>`**, contra a lista:
`Microsoft.EntityFrameworkCore`, `Microsoft.Data.SqlClient`, `Dapper`, `MongoDB.Driver`,
`StackExchange.Redis`, `Azure.*`, `AWSSDK.*`, `Newtonsoft.Json`, `System.Text.Json.Serialization`,
`Microsoft.Extensions.DependencyInjection`, `Microsoft.Extensions.Logging`, `AutoMapper`, `MediatR`,
`Refit`, `Hangfire`. Exclua `Migrations/`, `*.g.cs`, `*.Designer.cs`, `obj/` e projetos de teste.
**Se a solution usa `global using`, a passada (2) sozinha não conclui nada** — diga isso no relatório
em vez de afirmar que o domínio está limpo."

### b3 — `DbContext` no controller: falso positivo em VSA, e contradiz a própria tabela de escolha
**Trecho** (ARQ:39): "| `DbContext` referenciado em controller | Pula a camada de aplicação |"

**Problema.** ARQ:80 define Vertical Slice como "cada slice tem endpoint, handler, validação e
**acesso a dados** juntos", e ARQ:86 diz que misturar arquiteturas é maduro. Em VSA, o handler
**é** a camada de aplicação e injetar `DbContext` nele é idiomático; em leitura trivial, injetar no
próprio endpoint também é escolha endossada. A tabela mecânica marcaria como violação o desenho que
a tabela de escolha recomenda. Um revisor que segue as duas seções se contradiz no mesmo relatório.

**Correção.** "| `DbContext` em controller/endpoint | **Depende da arquitetura declarada.** Em Clean
Architecture: pula a camada de aplicação 🟠. Em VSA: **não é achado** — o handler do slice é a
camada de aplicação. O achado independente de arquitetura é **regra de negócio** junto do acesso a
dados no endpoint, ou `DbContext` num controller de uma solution que tem projeto `Application`
justamente para isso. Antes de aplicar esta linha, determine a arquitetura pretendida."

### b4 — `internal` ausente em tudo: falso positivo em quase toda solution de linha de negócio
**Trecho** (ARQ:44): "| `internal` ausente em tudo | Toda classe pública é superfície de
acoplamento |"

**Problema.** `internal` só restringe no limite de **assembly**. Em Clean Architecture, os tipos de
Domain e Application **precisam** ser `public` para a Api e a Infrastructure os consumirem; em VSA
de projeto único, `internal` não muda nada porque não há limite a cruzar. Aplicada literalmente, a
linha gera achado em praticamente todo projeto correto — e o custo de `public` numa aplicação que
não é distribuída como pacote é zero, porque não há consumidor externo a versionar. `internal` +
`InternalsVisibleTo` para teste é a contra-medida usual e viraria mais um "achado".

**Correção.** "| Superfície pública maior que a fronteira | **Só é achado em dois contextos.**
(1) **Biblioteca/NuGet publicado:** todo tipo `public` é compromisso de versionamento — aqui a linha
vale integralmente. (2) **Monolito modular:** o interior do módulo deve ser `internal` e o módulo
deve expor **um** assembly de contratos; se tudo é `public`, não existe fronteira, existe pasta.
**Não é achado** em Clean Architecture em camadas (os tipos precisam ser `public` para a camada de
cima) nem em VSA de projeto único (`internal` não restringe nada dentro do mesmo assembly). E
`InternalsVisibleTo` para o projeto de teste é prática correta, não violação. |"

### b5 — `Microsoft.AspNetCore.*` "fora da camada de API" não é invariante em VSA nem em módulo
**Trecho** (ARQ:38): "| `using Microsoft.AspNetCore.*` fora da camada de API | Web vazando para
dentro |"

**Problema.** Em VSA de projeto único **tudo** é a camada de API, então a checagem nunca dispara —
falso negativo total no cenário que ARQ:80 recomenda como default. Em monolito modular, cada módulo
registra os próprios endpoints (`MapGroup`), então `Microsoft.AspNetCore.Routing`/`.Http` dentro do
módulo é correto — falso positivo. O invariante real e estável é mais estreito.

**Correção.** "| Tipo de web no **domínio** (`HttpContext`, `IFormFile`, `IActionResult`,
`ControllerBase`, `IHttpContextAccessor`, `ProblemDetails`) | Web vazando para dentro. Este é o
invariante que vale em **qualquer** arquitetura. `Microsoft.AspNetCore.*` num módulo ou num slice
que registra os próprios endpoints **não** é violação. |" Vale acrescentar como linha própria:
`IHttpContextAccessor` injetado em regra de negócio (usuário atual como estado ambiente) 🟠.

### b6 — `System.Net.Http` em Application/Domain: pega o menos importante
**Trecho** (ARQ:37): "| `using System.Net.Http` em Application ou Domain | Detalhe de transporte
vazando |"

**Problema.** Também derrotado por `global using`, e cego para o vazamento pior, que é **a porta com
tipo de transporte na assinatura**: `Task<HttpResponseMessage> GetAsync(...)` declarado numa
interface da Application é vazamento completo com ou sem o `using` visível, porque quem implementa e
quem consome ficam presos ao transporte. Também não cobre `Refit`, `Grpc.Net.Client`,
`System.Net.Http.Json`.

**Correção.** "| Tipo de transporte na **assinatura** de porta da Application
(`HttpResponseMessage`, `HttpRequestMessage`, `HttpStatusCode`, `IRestResponse`, tipo gerado por
gRPC/Refit, DTO de SDK) | Detalhe de transporte vazando. Mais grave que o `using`, porque prende
todos os implementadores e consumidores ao transporte. A porta deve falar em tipo do domínio e
devolver `Result`/exceção traduzida. |"

### b7 — Ciclos entre pastas/módulos: o arquivo reconhece o problema e não dá a checagem
**Trecho** (ARQ:41): "| Ciclo de referência entre projetos | ... (o compilador impede entre
projetos, mas ciclos entre pastas/módulos passam) |"

**Problema.** A ressalva está correta e é onde mora o problema real, e nenhuma checagem é oferecida
para ela. Num monolito modular ou em VSA o compilador não ajuda, e "desenhe o grafo mentalmente"
(ARQ:21) não escala além de meia dúzia de módulos.

**Correção.** Acrescentar: "**Como checar ciclo dentro de um assembly:** grafo de `using` entre os
namespaces raiz dos módulos/slices (`Modules.Billing.*` referencia `Modules.Catalog.*` e
vice-versa), ou ferramenta — `NetArchTest`/`ArchUnitNET` num teste que falha o build. Se o projeto
não tem esse teste, **a recomendação é criá-lo**: sem ratchet automatizado, fronteira dentro de um
assembly volta a furar no próximo sprint."

### b8 — "Dois módulos acessando as tabelas um do outro" não tem sinal detectável declarado
**Trecho** (ARQ:43 / ARQ:99): "| Dois módulos acessando as tabelas um do outro | Fronteira de módulo
furada |"

**Problema.** Está na tabela de "sinais verificáveis, não interpretação" e não é verificável como
escrito. Nenhum `using` revela isso.

**Correção.** Acrescentar os sinais: "`DbSet<T>` de entidade de outro módulo no `DbContext` do
módulo; `ProjectReference` para o assembly de **implementação** de outro módulo (e não para o de
contratos); FK ou `HasOne` atravessando módulos; `join` em query sobre tabela de outro módulo;
migration de um módulo alterando tabela de outro; ausência de schema por módulo
(`ToTable(..., schema: \"billing\")`) — sem schema separado não há como distinguir dono de invasor."

### b9 — "Abra a maior classe": LOC é proxy fraco e escolhe o arquivo errado
**Trecho** (ARQ:24): "**Abra a maior classe.** God class é o sintoma arquitetural mais comum."

**Problema.** As maiores classes de uma solution .NET real são tipicamente `*ModelSnapshot.cs` de
migration, `*.Designer.cs`, mapeamento gerado e tabelas de constantes — nenhuma é achado. E a
métrica que correlaciona com risco arquitetural não é tamanho: é **número de colaboradores de
negócio injetados** (excluindo `ILogger`, `IOptions`, `TimeProvider`), **fan-in** e **frequência de
mudança**. Além disso, "o sintoma arquitetural mais comum" é discutível: em .NET corporativo, os dois
mais comuns são o `Common`/`Shared` inflado (ARQ:97) e o layering de repasse (ARQ:92) — ambos já
estão no arquivo, o que enfraquece a afirmação.

**Correção.** "**Abra a classe com mais dependências injetadas**, não a maior. Conte colaboradores
de negócio, excluindo cross-cutting (`ILogger`, `IOptions`, `TimeProvider`). Se houver histórico
git, cruze com frequência de mudança: acoplamento alto + churn alto é onde o defeito arquitetural
custa. Exclua código gerado (`*ModelSnapshot.cs`, `*.Designer.cs`, `*.g.cs`), que domina qualquer
ranking por LOC."

### b10 — "Verifique onde a transação começa e termina" sem sinal a procurar
**Trecho** (ARQ:25): "**Verifique onde a transação começa e termina.** Fronteira de transação difusa
é fonte de bug de consistência."

**Problema.** É o passo 6 de 7 numa lista que se apresenta como ordem operacional, e é o único sem
nada concreto a procurar. Na prática o revisor pula.

**Correção.** "**Verifique onde a transação começa e termina.** Procure, nesta ordem: contagem de
call sites de `SaveChanges`/`SaveChangesAsync` **por fluxo** (mais de um sem transação explícita =
commit parcial possível); `BeginTransaction`, `TransactionScope`, `Database.UseTransaction`;
`EnableRetryOnFailure` no `UseSqlServer` combinado com `BeginTransaction` manual (**lança em
runtime** — exige `CreateExecutionStrategy`); `SaveChanges` dentro de `foreach`; publicação em
fila/HTTP **antes** do commit, ou depois do commit sem outbox; token de concorrência
(`IsRowVersion`/`[Timestamp]`) em entidade com escrita concorrente."

### b11 — A tabela não isenta código gerado, migrations e teste
**Trecho** (ARQ:30): "Sinais verificáveis, não interpretação:"

**Problema.** Nenhuma linha da tabela tem escopo de arquivos. Em qualquer solution real, aplicar as
onze linhas sem isenção produz achados em `Migrations/`, `obj/`, `*.g.cs`, `*.Designer.cs`,
`*ModelSnapshot.cs` e nos projetos de teste (onde `DbContext` no "controller" e `internal` ausente
são normais). Isso é ruído que consome o orçamento de achados definido em `SKILL.md`:90.

**Correção.** Acrescentar antes da tabela: "**Escopo:** aplique só a código de produção escrito à
mão. Exclua `obj/`, `bin/`, `Migrations/`, `*.g.cs`, `*.Designer.cs`, `*ModelSnapshot.cs`,
`*.generated.cs` e projetos de teste. Achado em código gerado é ruído."

---

# (c) LACUNAS CRÍTICAS

### c1 — 🔴 MOD: falta o caminho oficial de coexistência (`SystemWebAdapters`)
**Trecho** (MOD:49): "`FormsAuthentication` não é diretamente compatível com o .NET moderno. Planeje
isso primeiro." e MOD:36: "**YARP** hospedado no .NET moderno, com fallback para a aplicação antiga".

**Problema.** O arquivo identifica corretamente sessão e autenticação como os dois maiores atrasos e
então para, deixando o leitor com "planeje" e nenhum mecanismo. Existe caminho suportado pela
Microsoft, desenhado exatamente para isso, e ele está ausente:
`Microsoft.AspNetCore.SystemWebAdapters` (a "incremental ASP.NET to ASP.NET Core migration"), que
oferece **remote app authentication** (a app Core delega a autenticação para a app Framework, então
o cookie de Forms Auth continua valendo), **remote app session** (a app Core lê e escreve a sessão
da app Framework por canal HTTP autenticado) e adaptadores de `System.Web.HttpContext` para o código
que ainda usa `HttpContext.Current`. É a diferença entre "o degrau 6 é caro" e "o degrau 6 é
viável", e vale mais que qualquer outro parágrafo do arquivo.

**Correção — nova subseção após "Strangler Fig na prática":**
"**Coexistência suportada: `SystemWebAdapters`.** Antes de desenhar solução própria para sessão e
login compartilhados, considere `Microsoft.AspNetCore.SystemWebAdapters`, que é o caminho incremental
documentado pela Microsoft:
- **Remote app authentication:** a app .NET moderno delega a autenticação para a app .NET Framework.
  O cookie existente, inclusive `FormsAuthentication`, continua sendo a fonte de verdade. Remove o
  bloqueio do passo 0.
- **Remote app session:** a app moderna lê e grava a sessão da app antiga por canal HTTP
  autenticado, com trava (`Sessão` read-only vs read-write). Custa latência, e resolve
  incrementalmente.
- **Adaptadores de `System.Web.HttpContext`:** permitem mover código que usa `HttpContext.Current`
  antes de reescrevê-lo, o que muda o custo do degrau 4.
Os adapters são muleta de transição com custo de latência e acoplamento entre as duas apps: sirva
para migrar, não para arquitetura final. Alternativa a considerar em paralelo: **parar de
compartilhar cookie e mover as duas apps para um IdP central (OIDC)** — mais trabalho de uma vez,
sem dívida de transição. Caminho manual, se nenhum dos dois: mover a app 4.x para cookie auth OWIN
(Katana) e compartilhar o cookie via `Microsoft.Owin.Security.Interop` + key ring de Data Protection
comum (mesmo diretório e mesmo `ApplicationName`). `FormsAuthentication` puro não compartilha de
forma alguma."

### c2 — 🔴 MOD: "diferença de comportamento silenciosa" precisa nomear as diferenças
**Trecho** (MOD:51): "Serialização de JSON, arredondamento de `decimal`, tratamento de nulo em query
e cultura padrão mudam entre EF6 e EF Core, e entre Newtonsoft e `System.Text.Json`."

**Problema.** A categoria está certa e genérica ao ponto de ser inacionável — e um item está errado:
o arredondamento de **`decimal`** não mudou (`decimal` é exato e `Math.Round` mantém semântica); o
que mudou foi a formatação/parse de **`double`/`float`**, que no .NET Core 3.0 passou a produzir o
menor round-trip. Como esta é a classe de bug que passa por todo teste e aparece em produção, a
lista precisa ser específica.

**Correção — substituir o bullet por lista nomeada:**
"- **Diferença de comportamento silenciosa.** Compare respostas lado a lado antes de trocar a rota,
  e verifique especificamente:
  - **`System.Text.Json` é case-sensitive por padrão**; `Newtonsoft` é case-insensitive. Payload que
    chegava preenchido passa a chegar com propriedade nula, sem erro. É o item nº 1.
  - **STJ exige ISO 8601** para `DateTime` e não aceita os formatos que o Newtonsoft aceitava; e
    serializa `TimeSpan`/`DateTimeOffset` diferente.
  - **STJ não serializa campos nem propriedades não-públicas por padrão**, e ignora
    `[JsonProperty]`/`[JsonIgnore]` do Newtonsoft (atributos diferentes).
  - **Formatação de `double`/`float` mudou no .NET Core 3.0** (menor round-trip). `decimal` **não**
    mudou.
  - **NLS → ICU (.NET 5+):** ordenação e comparação de string com cultura mudam de resultado no
    Windows. Se comparação de string tem semântica de negócio, é risco silencioso — fixe
    `StringComparison.Ordinal` no que é identificador.
  - **EF6 → EF Core:** `null` em comparação segue semântica diferente; `Include` split vs single
    query; conversão de `decimal` sem precisão declarada trunca; `string.Contains` traduz diferente;
    e **avaliação no cliente**, que o EF6 fazia em silêncio, no EF Core 3.0+ **lança**.
  - **`Microsoft.Data.SqlClient` 4.0+: `Encrypt=true` por padrão.** Conexão que funcionava falha."

### c3 — 🔴 Versionamento de API está ausente da skill inteira
**Trecho** (ARQ:70-71): "Só tradução: HTTP para caso de uso e resultado para HTTP. Verifique: regra
de negócio no endpoint, `DbContext` injetado no controller, entidade devolvida como resposta,
ausência de `CancellationToken`, ausência de autorização."

**Problema.** Nem `arquitetura.md`, nem `dotnet-moderno.md`, nem o catálogo mencionam versionamento
de API (`grep` por "versionamento", "ApiVersion": zero ocorrência). É a decisão de fronteira mais
irreversível que uma API toma — depois que há cliente externo, escolher errado custa uma migração de
consumidores. E o arquivo já se preocupa com o problema adjacente ("entidade devolvida como
resposta"), o que torna a ausência mais visível.

**Correção — acrescentar à seção "API / apresentação":**
"**Versionamento e evolução do contrato.** Verifique, se a API tem consumidor que você não controla:
- Existe estratégia declarada? `Asp.Versioning.*` (o antigo `Microsoft.AspNetCore.Mvc.Versioning`)
  com **segmento de URL** (`/v1/...`) é o default defensável: cacheável, visível em log e trivial de
  rotear no gateway. Header e query string funcionam e escondem a versão da observabilidade.
- **Mudança aditiva não precisa de versão nova.** Campo novo opcional na resposta e parâmetro novo
  opcional na requisição são compatíveis. Criar `v2` para isso multiplica manutenção sem ganho —
  aponte como overengineering.
- **Mudança que exige versão nova:** remover ou renomear campo, mudar tipo, apertar validação,
  mudar semântica de status code, mudar o default de um parâmetro.
- **Depreciação:** versão marcada como deprecated, header `Sunset` com data, e um documento OpenAPI
  **por versão**. Sem data de fim, nenhuma versão morre.
- **Achados 🟠:** ausência de qualquer versionamento em API pública; versão no contrato mas
  compartilhando o mesmo DTO entre v1 e v2 (mudar o DTO quebra v1 — o ponto de versionar é
  justamente ter contratos separados); versionar por *entidade* em vez de por *contrato*."

### c4 — 🔴 Fronteira de transação: citada três vezes, nunca especificada
**Trechos** (ARQ:25, ARQ:60, ARQ:100). O arquivo declara a fronteira de transação como um dos sete
passos do review e um dos smells, e nunca diz o que a torna correta.

**Correção — nova seção em `arquitetura.md`:**
"## Fronteira de transação

O que decide a maior parte dos casos, e quase nunca é dito:

- **`SaveChanges` já é atômico.** Uma chamada envolve todas as alterações rastreadas numa transação
  (quando o provedor suporta). Não recomende `BeginTransaction` para um único `SaveChanges` — é
  ruído.
- **Transação explícita é necessária** para: dois ou mais `SaveChanges` que devem cair juntos;
  `SaveChanges` + comando SQL cru (`ExecuteSqlRaw`, `ExecuteUpdate`, `ExecuteDelete`, que **não**
  participam do change tracker); dois `DbContext`; leitura que precisa de nível de isolamento
  específico.
- **🔴 Armadilha que lança em produção:** com `EnableRetryOnFailure` ligado (obrigatório em Azure
  SQL), `Database.BeginTransaction()` manual lança `InvalidOperationException`. A transação precisa
  ser criada dentro de `Database.CreateExecutionStrategy().ExecuteAsync(...)`, porque o retry precisa
  poder reexecutar o bloco inteiro. É achado mecânico: procure `EnableRetryOnFailure` e
  `BeginTransaction` no mesmo projeto.
- **Um agregado por transação (DDD).** Duas raízes de agregado no mesmo commit é sinal de fronteira
  de agregado errada, ou de que deveria haver consistência eventual entre elas. Não é "transação
  difusa": é decisão, e precisa estar escrita.
- **Efeito externo nunca dentro da transação.** Publicar em fila, chamar HTTP ou mandar e-mail antes
  do commit gera efeito sem estado quando o commit falha; depois do commit, sem outbox, gera estado
  sem efeito quando o processo morre. Só há três saídas honestas: outbox (insert do evento no
  **mesmo** `SaveChanges`), idempotência com reconciliação, ou aceitar a perda explicitamente.
- **Concorrência otimista, não transação longa.** Não segure transação durante interação de
  usuário. Use token de concorrência (`IsRowVersion`/`[Timestamp]`), capture
  `DbUpdateConcurrencyException` e traduza para **409**. Ausência de token em entidade com escrita
  concorrente é 🟠; transação aberta atravessando chamada externa é 🔴.
- **Isolamento.** O default do SQL Server é `READ COMMITTED` sem row versioning: leitor bloqueia
  escritor. `READ_COMMITTED_SNAPSHOT` costuma ser a decisão certa e é decisão **de banco**, não de
  código — se o time nunca decidiu, aponte. `NOLOCK` espalhado é 🟠: leitura suja e possibilidade de
  linha duplicada ou perdida na varredura.
- **Distribuída:** `TransactionScope` promovido a MSDTC não existe em .NET Core a .NET 6 e só existe
  no Windows em .NET 7+. Dois recursos no mesmo commit exige saga ou compensação, não
  `TransactionScope`."

### c5 — 🔴 Idempotência tem uma linha na skill inteira
**Trecho** — a única menção é `dotnet-moderno.md`:119: "Retry em operação não idempotente (POST de
cobrança) | 🔴 | Efeito duplicado. Exige chave de idempotência".

**Problema.** A linha identifica o sintoma e não existe nada sobre o desenho. Idempotência é
requisito de fronteira em três lugares que a skill toca — retry de HttpClient (`dotnet-moderno`),
outbox e Observer (catálogo), e a migração Strangler Fig, onde MOD:43 usa a palavra
"idempotentes" como critério de ordenação **sem definir como se consegue isso**. Também é o item que
o próprio arquivo de arquitetura precisa para fechar o outbox: outbox garante entrega
**at-least-once**, então o consumidor **tem** que ser idempotente, ou a garantia vira duplicata.

**Correção — nova seção em `arquitetura.md`:**
"## Idempotência nas fronteiras

Toda fronteira com retry precisa de idempotência, e todo retry existe (HTTP, fila, gateway,
usuário clicando duas vezes). Verifique nas três:

- **HTTP de escrita.** `PUT`/`DELETE` são idempotentes por definição; `POST` não é. Para `POST` que
  cria recurso ou move dinheiro: header `Idempotency-Key` fornecido pelo cliente, gravado com
  restrição de unicidade **na mesma transação** do efeito, e requisição repetida devolve a resposta
  original em vez de reexecutar. Sem unicidade no banco, duas requisições concorrentes passam pelas
  duas verificações.
- **Consumidor de mensagem.** Broker entrega **at-least-once**. Duplicata não é exceção, é operação
  normal: rebalanceamento, timeout de ack, redeploy. O consumidor precisa de dedup por
  `MessageId`/chave de negócio (inbox), ou de operação naturalmente idempotente
  (`UPDATE ... SET status = 'Paid' WHERE id = @id AND status = 'Pending'`, que é seguro repetir).
- **Chamada de saída.** Retry com backoff em `POST` sem chave de idempotência é 🔴. Se o fornecedor
  não aceita chave, o retry precisa ser precedido de consulta ("essa cobrança já existe?"), ou não
  haver retry.
- **Achados.** `Idempotency-Key` lido e guardado **depois** do efeito; dedup em cache em memória
  numa app com mais de uma instância; dedup sem TTL (tabela cresce para sempre);
  `Guid.NewGuid()` gerado no servidor como chave de dedup, que não deduplica nada porque muda a cada
  tentativa."

### c6 — 🟠 Monolito modular sem mecanismo de enforcement
**Trecho** (ARQ:83): "| **Monolito modular** | Vários subdomínios, mais de um time, quer fronteiras
sem custo de rede | Sistema pequeno, onde módulo vira só pasta com nome bonito |"

**Problema.** O arquivo diagnostica corretamente o modo de falha ("pasta com nome bonito") e não
oferece nada para evitá-lo. Sem mecanismo, monolito modular **sempre** degenera, porque a violação
compila.

**Correção — acrescentar à seção "O que verificar em cada camada":**
"### Módulo (monolito modular)

O que separa módulo de pasta. Verifique **todos**, porque falta de um derruba os outros:

- **Assembly por módulo, e contratos separados.** `Modules.Billing` (implementação, tipos
  `internal`) + `Modules.Billing.Contracts` (`public`, só DTO/evento/interface). Outros módulos
  referenciam **apenas** `.Contracts`. `ProjectReference` para o assembly de implementação de outro
  módulo é 🔴: a fronteira não existe.
- **Teste de arquitetura como ratchet.** `NetArchTest` ou `ArchUnitNET` num teste que falha o build
  quando um módulo referencia o interior de outro. Sem isso, a fronteira dura até o próximo prazo
  apertado. Se o projeto não tem, **essa é a primeira recomendação**, antes de qualquer
  reorganização de pasta.
- **Schema de banco por módulo.** `ToTable(..., schema: "billing")`, sem FK e sem `join`
  atravessando módulos. Referência entre módulos é por id, e a integridade é do dono. Um único
  `DbContext` com `DbSet<>` de todos os módulos é 🟠 mesmo com as pastas organizadas.
- **Comunicação declarada.** Leitura entre módulos: interface pública do módulo dono, síncrona,
  em processo. Efeito entre módulos: **evento**, com outbox se não puder ser perdido. Nunca ler a
  tabela do outro.
- **Registro no container por módulo.** Cada módulo expõe seu
  `AddBillingModule(IHostApplicationBuilder)`; o `Program.cs` chama N linhas e não conhece o
  interior. Se o `Program.cs` registra serviços internos dos módulos, o composition root virou
  acoplamento global.
- **Custo a declarar no review:** a fronteira só vale se o time aceitar não fazer `join`. Se a
  primeira demanda de relatório atravessar dois módulos por SQL, o desenho já foi abandonado — e a
  saída correta é uma **view de leitura** ou um read model, não furar o módulo."

### c7 — 🟠 Mensageria: outbox aparece três vezes sem nenhuma orientação de desenho
**Trechos** (CAT:49, CAT:193, CAT:353, ARQ:98). A skill recomenda outbox em quatro lugares e nunca
diz o que ele implica.

**Correção — acrescentar ao catálogo, na seção de aplicação, verba nova:**
"### Mensageria e outbox

- **Gatilho:** efeito que não pode ser perdido e não pode estar na mesma transação (integração,
  e-mail, outro módulo, outro sistema).
- **Outbox:** o evento é gravado numa tabela **no mesmo `SaveChanges`** que muda o estado; um
  publisher separado lê e publica com retry, marcando o que publicou. É isso que troca "avisa" por
  "garante".
- **A consequência que quase nunca é dita:** outbox entrega **at-least-once**, nunca
  exactly-once. Logo, **todo consumidor precisa ser idempotente**. Recomendar outbox sem recomendar
  idempotência do consumidor entrega duplicata com aparência de garantia.
- **Ordem:** só existe ordem dentro de uma partição/chave (`SessionId` no Azure Service Bus,
  partition key no Kafka). Fila com competing consumers **não** preserva ordem. Se o consumidor
  depende de ordem, ou particiona por chave de agregado, ou torna a mensagem
  auto-suficiente (estado completo, não delta).
- **Poison message:** consumidor sem limite de tentativas e sem dead-letter fica em loop infinito
  numa mensagem só, e a fila para. Ausência de DLQ é 🟠; DLQ sem alarme é 🟠, porque ninguém olha.
- **Versionamento de mensagem:** mensagem publicada é contrato como endpoint HTTP, com o agravante
  de haver mensagem em voo durante o deploy. Só mudança aditiva; campo novo opcional; consumidor
  tolerante ao que não conhece. Renomear campo de evento é breaking change silencioso.
- **Saga / process manager:** só quando há fluxo de várias etapas com compensação
  (`TransactionScope` distribuído não é opção). Coreografia (cada serviço reage) é mais simples e
  fica indepurável acima de três a quatro passos; orquestração (um coordenador explícito) custa um
  componente e é legível. Acima de três passos com compensação, prefira orquestração.
- **Licenciamento:** MassTransit e MediatR passaram a exigir licença comercial em versões recentes.
  Verifique antes de recomendar. Wolverine, ou consumidor escrito à mão sobre o SDK do broker."

### c8 — 🟠 Multi-tenancy ausente, com dois modos de falha 🔴 conhecidos
**Trecho** — nenhum. `grep` por "tenant"/"multi-tenan" em toda a skill retorna só
`SKILL.md`:62, num exemplo sobre Factory.

**Problema.** Multi-tenancy é a restrição arquitetural que **mais** limita as outras decisões
(migrations, cache, connection string, autorização, read model), e vazamento entre tenants é o
defeito de maior severidade possível numa aplicação de linha de negócio. Além disso interage
diretamente com dois itens que a skill já recomenda: CQRS (o lado de leitura pula o domínio, e com
isso pula o filtro de tenant) e `HybridCache` (chave sem tenant vaza dado entre clientes).

**Correção — nova seção em `arquitetura.md`:**
"## Multi-tenancy

Se o sistema atende mais de um cliente no mesmo deploy, a estratégia de isolamento precisa estar
escrita. Ela restringe migrations, cache, autorização e read models — e retrofit é caríssimo.

| Modelo | Cabe quando | Custo |
|---|---|---|
| **Linha (`TenantId` em cada tabela)** | Muitos tenants pequenos, mesmo schema, custo baixo por tenant | Risco de vazamento em **todo** query path. Exige filtro sistêmico, não filtro por query |
| **Schema por tenant** | Dezenas de tenants, alguma customização | Migration × N schemas; limite prático de algumas centenas |
| **Banco por tenant** | Poucos tenants grandes, exigência contratual/regulatória de isolamento, restore por tenant | Migration × N bancos, pool de conexão × N, custo de infra |

Verificações, em ordem de severidade:

- **🔴 Filtro de tenant não sistêmico.** No modelo de linha, `HasQueryFilter(e => e.TenantId ==
  _tenant.Id)` por entidade é o único desenho defensável — `Where(x => x.TenantId == ...)` escrito
  query a query vaza no primeiro esquecimento. Aponte também o que **contorna** o filtro:
  `IgnoreQueryFilters()`, Dapper e ADO cru, `FromSql` composto de forma errada, e view de
  relatório.
- **🔴 O filtro não protege escrita.** `HasQueryFilter` filtra leitura e **não impede** gravar linha
  com `TenantId` de outro tenant (ou nulo). Precisa de interceptor de `SaveChanges` que preencha e
  valide o `TenantId` das entidades adicionadas/modificadas.
- **🔴 Tenant capturado de estático ou de singleton.** O filtro global deve ler uma **propriedade de
  instância do `DbContext`** (populada por serviço scoped resolvido do `HttpContext`). Capturar de
  campo estático, de singleton, ou de variável fechada em `OnModelCreating` gera o pior bug possível:
  o primeiro tenant a subir define o filtro dos demais.
- **🔴 Chave de cache sem tenant.** `IMemoryCache`/`HybridCache`/Redis com chave
  `$"user:{id}"` em vez de `$"{tenantId}:user:{id}"` serve dado de um cliente para outro. Vale
  também para output caching (varie por tenant) e para `FrozenDictionary` de config carregado no
  startup.
- **🟠 CQRS + tenancy.** O lado de leitura que projeta direto do banco pula o domínio **e** pula
  qualquer verificação que estava no domínio. Se o filtro não está no `DbContext`, o read side é o
  primeiro lugar a vazar.
- **🟠 Resolução de tenant na borda, uma vez.** Subdomínio, claim ou header, resolvido em middleware
  e exposto como serviço scoped tipado (`ITenantContext`). Cada camada re-derivando o tenant de
  `HttpContext` é o mesmo problema de `IConfiguration` espalhado, com consequência de segurança.
- **🟠 Migration e onboarding.** Nos modelos de schema/banco por tenant, migration é operação de N
  execuções com falha parcial: precisa ser idempotente, ter registro de quem está em qual versão, e
  o provisionamento de tenant novo precisa ser automatizado — senão o degrau vira trabalho manual
  crescente.
- **🟠 Ruído entre tenants.** Um tenant grande consome a capacidade dos outros. Rate limiting e
  quota **por tenant**, não global."

### c9 — 🟡 Onde vive o worker/consumer não está no modelo de camadas
**Trecho** (ARQ:46-71): a seção "O que verificar em cada camada" tem Domain, Application,
Infrastructure e API. Não tem host de background.

**Problema.** `BackgroundService`, consumidor de fila, job agendado e publisher de outbox não são API
nem Infrastructure, e na prática caem no projeto de API — o que amarra processamento assíncrono ao
ciclo de vida e ao dimensionamento do processo web, e é uma decisão arquitetural real que o review
nunca examina. `dotnet-moderno.md`:212 cobre os defeitos **dentro** do `BackgroundService`, e não o
lugar dele.

**Correção — acrescentar:**
"### Host de background (worker, consumidor, job)

- Um `BackgroundService` hospedado no processo web amarra o processamento assíncrono ao
  dimensionamento e ao ciclo de vida do web: escalar HTTP escala o worker (e passa a haver N
  instâncias do mesmo job), e recycle de app pool mata trabalho em andamento. Aceitável em app
  pequena, **decisão a declarar** em qualquer outra.
- Host separado (`Worker`) referenciando Application/Infrastructure é o default para: consumidor de
  fila, publisher de outbox, job pesado, reprocessamento.
- Job com mais de uma instância exige **lease/lock distribuído** ou particionamento — senão N
  instâncias fazem o mesmo trabalho N vezes. Ausência disso num deploy com réplicas é 🔴.
- `IHostedService` não é agendador: sem persistência de estado, o job perde a janela num restart.
  Se a semântica é "todo dia às 3h, garantido", é agendador externo ou tabela de controle."

### c10 — 🟡 O smell do `Shared` inflado não tem contrapartida positiva
**Trecho** (ARQ:97): "| **Shared kernel inflado** | Projeto `Common`/`Shared` que tudo referencia e
que contém regra de negócio | Manter só primitivos e contratos estáveis; regra volta para o módulo
dono |"

**Problema.** "Primitivos e contratos estáveis" é abstrato demais para servir de critério, e este é
o smell mais comum em .NET corporativo. Sem lista concreta, todo review vira negociação.

**Correção.** Acrescentar: "**Cabe no `Shared`:** `Result`/`Error`, tipos de id fortemente tipados,
value objects primitivos sem regra (`Cpf`, `Email`, `Money`), abstrações de cross-cutting
(`ITenantContext`, wrapper de `TimeProvider`), constantes de código de erro, e **contratos de
evento**. **Não cabe:** entidade, `DbContext`, cliente HTTP, `Validator` de regra de negócio,
extension method que conhece dois módulos, e enum de negócio compartilhada entre módulos (é aqui que
o acoplamento entra disfarçado). **Teste:** se mudar um tipo do `Shared` obriga recompilar e
reimplantar todos os módulos, ele não é primitivo — é acoplamento com nome bonito."

### c11 — 🟡 Refatoração incremental sem ratchet e sem medição
**Trecho** (ARQ:112): "**Fase 3, inverter a dependência mais grave.** Mover a interface para o lado
de quem consome e ajustar as referências de projeto."

**Problema.** O plano de quatro fases é bom e não tem nada que impeça a regressão. Inversão feita na
fase 3 volta a furar na próxima entrega, porque nada falha quando alguém referencia de volta. E não
há critério de sucesso: o autor não sabe dizer se a refatoração funcionou.

**Correção.** Acrescentar entre as fases 3 e 4: "**Fase 3.5, travar o ganho.** Toda inversão feita
precisa de um teste que falhe se ela voltar: `NetArchTest`/`ArchUnitNET` (`Types.InAssembly(domain)
.ShouldNot().HaveDependencyOn("Microsoft.EntityFrameworkCore")`), ou `BannedSymbols.txt` com
`Microsoft.CodeAnalysis.BannedApiAnalyzers`, ou no mínimo `TreatWarningsAsErrors` sobre um analyzer
de camada. Sem esse ratchet, cada fase é temporária. E declare o critério de sucesso mensurável de
cada fase — 'a regra X passa a ter teste unitário sem banco', 'o domínio passa a ter zero
`PackageReference`' — porque 'ficou mais limpo' não é verificável e não sustenta a próxima fase
diante de prazo."

### c12 — 🟡 `AddTransient` de `IDisposable` é vazamento e não está na tabela de lifetimes
**Trecho** (CAT:265): "| `AddTransient` | injeção | objetos leves sem estado, validadores |"

**Problema.** Falta o modo de falha real de transient em .NET: **o container rastreia transients
`IDisposable` no escopo que os resolveu e só os descarta no fim do escopo**. Resolvido do provider
raiz (singleton, `IServiceProvider` de aplicação, hosted service sem escopo), o objeto vive até o
processo morrer — vazamento de memória crescente que se parece com leak de código de negócio.

**Correção.** Acrescentar após a tabela: "**Armadilha de `Transient` + `IDisposable`:** o container
rastreia transients descartáveis no escopo que os resolveu e só descarta no fim dele. Resolvido do
provider **raiz** (dentro de singleton, ou via `IServiceProvider` da aplicação), o objeto vive até o
processo terminar — memória crescendo sem culpado óbvio. Regra: não registre `IDisposable` como
`Transient` se ele pode ser resolvido pela raiz; use `Scoped`, ou uma factory que devolve o objeto
para o chamador descartar com `using` (e nesse caso o container não é o dono)."

### c13 — 🟡 Options: binding ignora chave desconhecida em silêncio
**Trecho** (CAT:274): "`AddOptions<T>().BindConfiguration(...).ValidateDataAnnotations()
.ValidateOnStart()`"

**Problema.** A receita está certa e não protege do erro mais comum de configuração: **chave errada
no `appsettings.json` é ignorada em silêncio**, e a propriedade fica com o default. `ValidateOnStart`
pega propriedade obrigatória faltando, e **não** pega `"TimeoutSeconds"` escrito onde a classe espera
`"TimeoutInSeconds"` quando há default — a app sobe com o valor errado. Falta também
`IValidateOptions<T>` para validação de campo cruzado, que `DataAnnotations` não faz.

**Correção.** Acrescentar: "Duas coisas que essa receita **não** cobre: (1) **chave desconhecida é
ignorada em silêncio** — `"TimeoutSeconds"` no JSON onde a classe tem `TimeoutInSeconds` deixa o
default valendo e a app sobe. Ligue `BinderOptions.ErrorOnUnknownConfiguration = true` na seção, ou
teste a configuração de produção contra o tipo; (2) **validação de campo cruzado** ('se `UseSsl`,
então `CertPath` obrigatório') não é `DataAnnotations` — é `IValidateOptions<T>`. E `ValidateOnStart`
só roda se o host realmente inicia: em teste que não sobe o host, a validação não acontece."

## Rejeitados (parecem lacunas e estão cobertos em arquivo vizinho)

Registrado para o auditor não reabrir:

- Async, `async void`, sync-over-async, `CancellationToken`, `Task.WhenAll` sobre `DbContext` →
  `dotnet-moderno.md`:28-59.
- N+1, `AsNoTracking`, `SaveChanges` em loop, `Skip/Take` sem `OrderBy`, SQL injection em
  `FromSqlRaw`, lazy loading → `dotnet-moderno.md`:90-108.
- Captive dependency, Service Locator, `IServiceScopeFactory` em `BackgroundService` →
  `dotnet-moderno.md`:61-88 e `catalogo-patterns.md`:96-99.
- Retry/timeout/circuit breaker, socket exhaustion → `dotnet-moderno.md`:110-123.
- Segredo versionado, IDOR, CORS, ordem de middleware, hash de senha →
  `dotnet-moderno.md`:126-134 e 238-250.
- `ProblemDetails` (RFC 9457) e `IExceptionHandler` → `dotnet-moderno.md`:155-160.
- Defeitos internos de `BackgroundService` → `dotnet-moderno.md`:212-220 (o que falta é **onde ele
  vive**, ver c9).
- Restrições de versão de linguagem em `net4x`, substitutos de API →
  `restricoes-versoes.md` inteiro (o que falta é o item de EF6/`netstandard`, ver a14).

---

# (d) CALIBRAÇÃO DA ESCOLHA DE ARQUITETURA

### d1 — A tabela mistura dois eixos ortogonais numa coluna
**Trecho** (ARQ:77-84): a tabela lista, no mesmo eixo, "Um projeto só", "Vertical Slice",
"Clean Architecture", "DDD tático + Clean", "Monolito modular", "Microsserviços".

**Problema.** São **dois eixos independentes**: topologia de implantação (um projeto / monolito
modular / microsserviços) e organização de código (VSA / Clean / DDD). Um monolito modular é
composto de módulos que internamente são VSA ou Clean; microsserviço tem organização interna própria.
Apresentados como seis opções de uma lista, o leitor lê como escolha exclusiva. A observação de
ARQ:86 ("é perfeitamente válido um sistema misturar") tenta consertar depois, mas a estrutura da
tabela já empurrou a leitura errada — e é a estrutura que o revisor copia.

**Correção.** Quebrar em duas tabelas e nomear a relação: "**Eixo 1 — topologia:** um projeto,
monolito modular, serviços separados. Decidido por fronteira organizacional e necessidade de deploy
independente. **Eixo 2 — organização interna (por módulo, não pela solution):** VSA, Clean, Clean +
DDD tático. Decidido por complexidade de domínio. Os eixos são independentes: um monolito modular
com quatro módulos pode ter três em VSA e um em Clean + DDD, e essa é a configuração madura mais
comum em .NET, não uma inconsistência."

### d2 — 🔴 "Não cabe VSA quando há regra compartilhada" é conselho ruim
**Trecho** (ARQ:80): "| **Vertical Slice** | ... | Regras muito compartilhadas entre slices, gerando
duplicação real |"

**Problema.** Regra compartilhada **não** é motivo para abandonar VSA, e o conselho leva o time à
migração arquitetural mais caro possível (justamente o que ARQ:75 proíbe) para resolver um problema
que se resolve extraindo a regra. VSA organiza o **eixo de request handling**; ela nunca proibiu
domínio compartilhado. A resposta correta é: extrair a regra para o domínio (ou para um serviço de
domínio) e **manter os slices**, que é como VSA é praticada por quem a propôs. Cenário real onde o
conselho faz dano: sistema de 60 endpoints em VSA, aparece regra de precificação usada por 8 slices,
o time lê esta linha e propõe reestruturar em Clean Architecture — semanas de trabalho, risco alto,
quando a solução era uma classe `PricingPolicy` no domínio.

**Correção.** "| **Vertical Slice** | Muitas features independentes, time pequeno ou médio, CRUD com
alguma regra. Cada slice tem endpoint, handler, validação e acesso a dados juntos |
**Invariantes que atravessam muitas features** e precisam ser garantidas em todo caminho de escrita
(o lugar de garantir isso é um agregado, não N slices); **time grande precisando de fronteira
imposta**, porque slice não impõe nada — nada impede o slice A de ler a tabela do slice B;
**disciplina baixa**, porque VSA sem revisão degenera em copy-paste com validação divergente entre
slices que deveriam concordar.
**Não é motivo para trocar de arquitetura:** regra compartilhada entre slices. Extraia a regra para
o domínio e mantenha os slices — VSA organiza o handling da requisição, nunca proibiu domínio
compartilhado. |"

### d3 — 🟠 O custo de Clean Architecture está descrito como número de projetos
**Trecho** (ARQ:81): "| **Clean Architecture** | ... | CRUD. Aqui ela cobra 4 projetos e entrega
pouco |"

**Problema.** Contradiz a abertura do próprio arquivo (ARQ:3: "não sobre quantidade de camadas") e
descreve o custo errado. Quatro projetos custam algumas horas, uma vez. O custo recorrente de Clean
Architecture é o **imposto por mudança**: um campo novo atravessa entidade, configuração de EF,
comando, handler, DTO de request, DTO de response, mapeamento e teste — e é isso que cansa o time em
CRUD. Como está, um time pode "resolver" a objeção fazendo Clean em um projeto com pastas e
concluindo que o custo desapareceu.

**Correção.** "| **Clean Architecture** | Domínio com complexidade real, vida longa, mais de um
consumidor, exigência de testabilidade forte | CRUD, e **caminhos de leitura/relatório**, onde o
custo real não são os 4 projetos (isso é uma vez) e sim o **imposto por mudança**: um campo novo
atravessa entidade, configuração, comando, handler, DTO de entrada, DTO de saída, mapeamento e
teste. Nota: Clean é sobre **direção de dependência**, não sobre contagem de projetos — dá para
fazer em um projeto com pastas mais um teste de arquitetura, e essa costuma ser a versão certa para
sistema médio. |"

### d4 — 🟠 Faltam duas linhas para as formas mais comuns de sistema .NET
**Trecho** (ARQ:77-84): a tabela cobre só aplicação web/API de linha de negócio.

**Problema.** Perguntado "qual arquitetura para isso", o revisor recomenda Clean ou VSA para dois
tipos de sistema onde as duas são a pergunta errada:
1. **Worker / serviço de integração** (consome fila, ETL, sincronização, sem HTTP): as decisões que
   determinam sucesso são idempotência, ordenação, poison message, checkpoint e reprocessamento.
   Nenhuma linha da tabela menciona nada disso, e "Clean Architecture" aplicado a um consumidor sem
   discutir at-least-once entrega um consumidor bem-camadado que duplica cobrança.
2. **Biblioteca / pacote NuGet:** a arquitetura **é** a superfície pública e o compromisso de
   versionamento (`public` vs `internal`, `[Obsolete]`, SemVer, `sealed` por padrão, multi-target).
   É o único contexto onde a linha ARQ:44 sobre `internal` vale integralmente, e a tabela não tem
   linha para ele.

**Correção.** Acrescentar:

| Arquitetura | Cabe quando | Não cabe quando |
|---|---|---|
| **Worker / consumidor** (pipeline + handlers, sem camada web) | Consumidor de fila, ETL, sincronização, job. Organize por **mensagem/etapa**, não por camada web. As decisões que decidem o resultado são **idempotência, ordenação, DLQ, checkpoint e reprocessamento** — resolva-as antes de discutir camadas | Fluxo é síncrono e o chamador precisa da resposta. Aí é API, e fila só adiciona latência e complexidade |
| **Biblioteca / pacote** (superfície pública mínima + interior `internal`) | Código consumido por quem você não controla. A arquitetura **é** a API pública: `internal` por padrão, `sealed` por padrão, `[Obsolete]` antes de remover, SemVer, multi-target explícito | Código só desta solution. Aí `public` não custa nada e tratar como pacote é cerimônia |

### d5 — 🟠 Multi-tenancy deveria ser pergunta anterior à tabela
**Trecho** (ARQ:73): "## Escolha de arquitetura" — a seção não pergunta sobre tenancy.

**Problema.** Se o sistema é multi-tenant, o modelo de isolamento (linha / schema / banco) restringe
mais decisões do que qualquer linha da tabela: define se migration é 1 ou N execuções, se cache
precisa de discriminador, se connection string é estática ou resolvida por requisição, se o read
model de CQRS é seguro, e se módulos podem compartilhar `DbContext`. Recomendar arquitetura antes de
saber isso é recomendar no escuro.

**Correção.** Acrescentar antes da tabela: "**Duas perguntas antes de olhar a tabela**, porque elas
restringem mais que qualquer linha dela: (1) **é multi-tenant?** Se sim, o modelo de isolamento
(linha / schema / banco) condiciona migration, cache, connection string, autorização e read model —
ver a seção Multi-tenancy; (2) **quem consome, e você controla o consumidor?** Consumidor externo
implica versionamento de contrato e deprecação, o que muda o desenho da borda independentemente da
arquitetura interna escolhida."

### d6 — 🟡 Microsserviços: falta a linha divisória que realmente decide
**Trecho** (ARQ:84): "| **Microsserviços** | Times independentes, necessidade real de escala e
deploy separados, domínio já estabilizado | Time pequeno, domínio instável. Custo operacional supera
o ganho |"

**Problema.** Os critérios estão certos e faltam os dois testáveis. O que separa microsserviço de
monolito distribuído é **propriedade exclusiva de dados** (nenhum outro serviço lê a base dele) e
**capacidade de deploy sem coordenação**. Sem esses dois, "times independentes" não acontece,
independente de quantos processos existam. O arquivo tem o smell "Distributed monolith" (ARQ:98) e
não conecta ao critério de entrada.

**Correção.** "| **Microsserviços** | Times independentes, necessidade real de escala e deploy
separados, domínio já estabilizado. **Dois testes de entrada, ambos obrigatórios:** cada serviço é
**dono exclusivo** dos seus dados (nenhum outro lê a base dele, nem para relatório), e cada serviço
**implanta sem coordenação** com os demais | Time pequeno, domínio instável, **ou banco
compartilhado** — banco compartilhado transforma microsserviços em monolito distribuído com custo de
rede e sem nenhum benefício (ver o smell "Distributed monolith"). Custo operacional supera o
ganho |"

### d7 — 🟡 DDD tático sem DDD estratégico
**Trecho** (ARQ:82): "| **DDD tático + Clean** | Domínio central do negócio, invariantes complexas,
linguagem própria, especialista de domínio disponível | Domínio de suporte ou genérico. Não faça DDD
em cadastro auxiliar |"

**Problema.** Bem calibrado, e omite que a parte de DDD que decide fronteira de módulo é a
**estratégica** (bounded context, subdomínio core/suporte/genérico, context map). Sem ela, "DDD
tático" é um conjunto de padrões aplicado a fronteiras erradas, e o arquivo já usa vocabulário
estratégico ("subdomínios", "domínio de suporte ou genérico") sem nomeá-lo — então o leitor não tem
como saber que existe uma etapa anterior.

**Correção.** Acrescentar após a tabela: "Nota sobre DDD: a parte que decide **onde ficam as
fronteiras** é a estratégica (bounded context, classificação core/suporte/genérico, context map), e
ela vem antes de agregado e value object. Aplicar padrões táticos dentro de fronteiras erradas
produz agregados que não protegem nada e é o modo de falha mais comum de 'adotamos DDD'. Em review:
se o time nomeia agregados mas não consegue dizer quais são os bounded contexts e qual é o core, o
achado é a fronteira, não o padrão."

---

## Ordem sugerida de correção

Por risco de conselho ruim × frequência com que o cenário aparece:

1. **d2** (VSA/regra compartilhada) e **b3** (`DbContext` em controller): são contradições internas
   que fazem o revisor se contradizer no mesmo relatório.
2. **a13**, **a14**, **c1** (MOD: degrau 3 impossível, `netstandard2.0` × EF6, `SystemWebAdapters`):
   é o trecho onde o arquivo pode inviabilizar um projeto real.
3. **c4** e **b10** (fronteira de transação): já é passo declarado do review e está vazio.
4. **b1**/**b2** (grafo de dependências × `global using`): a checagem declarada como de maior retorno
   tem falso negativo estrutural.
5. **c8** e **c5** (multi-tenancy, idempotência): as duas lacunas com consequência 🔴.
6. **b4**, **b5**, **b11** (`internal`, `Microsoft.AspNetCore.*`, escopo de arquivos): geradores de
   ruído que consomem o orçamento de achados.
7. **a2**, **a7**, **a8**, **a9**, **a15**, **a16**, **a17** (correções factuais pontuais).
8. **c3**, **c6**, **c7**, **c9**–**c13**, **d1**, **d3**–**d7** (lacunas e calibração restantes).
