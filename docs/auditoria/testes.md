# Auditoria técnica: teste e testabilidade

**Data:** 2026-08-14
**Perspectiva:** especialista em testes .NET
**Nenhum arquivo auditado foi alterado.**

## Escopo auditado

| # | Arquivo | Parte |
|---|---|---|
| 1 | `dotnet-code-review/designpatterns/references/solid-smells.md` | seção "Testabilidade: as seams" (l. 194-209) |
| 2 | `dotnet-code-review/designpatterns-legacy/references/refatorar-sem-testes.md` | arquivo inteiro (l. 1-183) |
| 3 | `dotnet-code-review/designpatterns/references/catalogo-patterns.md` | Builder / Test Data Builder (l. 75-90) |

Arquivos **não** auditados, mas lidos para checar consistência das afirmações sobre teste, e citados quando contradizem o escopo auditado: `designpatterns-legacy/SKILL.md`, `designpatterns-legacy/references/restricoes-versoes.md`, `designpatterns/references/scoring.md`, `designpatterns-legacy/references/scoring-legacy.md`.

Fontes de verificação: documentação oficial da Microsoft (TimeProvider / FakeTimeProvider, EF Core Testing, Integration tests in ASP.NET Core, `System.Random`) e *Working Effectively with Legacy Code* (Feathers, 2004) para a nomenclatura das técnicas.

## Sumário executivo

O material é bom e acima da média do que circula em português. Os pontos fortes reais: a distinção entre teste de caracterização e teste de especificação está correta e bem explicada (l. 25-37); a orientação de **não** mockar `DbContext` está alinhada com a recomendação oficial do time de EF Core; a nomenclatura de Feathers está **toda correta**; e a filosofia de dois passos pequenos (l. 123) é exatamente a certa.

Os problemas se concentram em três eixos:

1. **Três frases minimizam risco de forma perigosa**, e são justamente as frases que o autor do código vai citar quando aprovar o refactor: "risco de regressão fica limitado a uma linha" (l. 66), "risco praticamente zero" / "praticamente nulo" (l. 123, 153) e "nenhum chamador quebra / nenhum chamador muda" (l. 91, 127).
2. **O procedimento de teste de caracterização produz rede falsa** em quatro situações comuns, e nenhuma delas está prevista.
3. **A skill não tem estratégia de teste.** Não há pirâmide, não há política de flakiness, não há nada sobre concorrência, snapshot, mutation testing, cobertura como métrica, nem — o mais grave — sobre como testar legado que depende de banco, que é o caso majoritário.

Contagem: 10 achados em (a), 8 em (b), 12 em (c), 7 em (d).

---

# (a) ERROS FACTUAIS

## A1 🔴 "`TimeProvider` não existe em .NET Framework" é factualmente falso

**Onde:** `restricoes-versoes.md:52` ("`TimeProvider` | Crie `IClock`...") e `designpatterns-legacy/SKILL.md:67` ("`TimeProvider` não existe; criar `IClock` próprio"). Contradiz diretamente a seam recomendada em `solid-smells.md:200`.

**O fato.** A documentação oficial lista `TimeProvider` como disponível em:

| Framework | Como |
|---|---|
| .NET 8+ | no runtime |
| .NET 5-7 | pacote `Microsoft.Bcl.TimeProvider` |
| **.NET Framework 4.6.2+** | pacote `Microsoft.Bcl.TimeProvider` |
| .NET Standard 2.0 | pacote `Microsoft.Bcl.TimeProvider` |

E `FakeTimeProvider` vem em `Microsoft.Extensions.TimeProvider.Testing`, que tem alvo `netstandard2.0` — portanto roda em `net472`.

**Por que é grave.** O próprio `restricoes-versoes.md:74-85` tem uma seção chamada "A ponte que muita gente não conhece" explicando que pacotes `Microsoft.Extensions.*` com alvo `netstandard2.0` funcionam em .NET Framework. `Microsoft.Bcl.TimeProvider` é exatamente esse caso, e ficou de fora. O resultado prático: a skill legada manda o autor escrever `IClock` na mão e um fake na mão, quando a abstração da plataforma mais um fake testado em produção estão a um `PackageReference` de distância — e, de bônus, isso alinharia as duas skills na mesma abstração.

**Correção sugerida.** Manter `IClock` como *fallback declarado*, com o motivo certo:

> `TimeProvider` existe em `net462+` via `Microsoft.Bcl.TimeProvider`, e `FakeTimeProvider` via `Microsoft.Extensions.TimeProvider.Testing` (`netstandard2.0`). Em `net472+` com `PackageReference`, prefira isso. Em `net45x`-`net461`, ou em projeto com `packages.config` onde adicionar pacote transitivo é doloroso, crie `IClock` com `DateTimeOffset UtcNow { get; }` — duas linhas, mesmo ganho.

## A2 🟠 `Thread.Sleep` não tem substituto em `TimeProvider`

**Onde:** `solid-smells.md:207` — "`Thread.Sleep` / `Task.Delay` em retry | `TimeProvider` com relógio falso avançando".

A linha junta duas coisas com soluções diferentes. A superfície de `TimeProvider` é `GetUtcNow()`, `GetLocalNow()`, `LocalTimeZone`, `GetTimestamp()`, `GetElapsedTime()`, `CreateTimer()`, mais as extensões `Task.Delay(TimeSpan, TimeProvider)`, `Task.WaitAsync(..., TimeProvider)` e `CreateCancellationTokenSource(TimeProvider, TimeSpan)`. **Não existe espera sincrônica.**

- `Task.Delay(ts)` → `Task.Delay(ts, timeProvider)` (ou `timeProvider.Delay(ts)` no pacote BCL). Funciona, é a recomendação certa.
- `Thread.Sleep(ts)` → **não há troca direta.** O caminho tem que virar assíncrono primeiro, ou a espera tem que sair para trás de um `protected virtual Esperar(TimeSpan)` / um `IDelay` próprio.

Como está, o review vai recomendar uma substituição que não compila — precisamente o erro que `restricoes-versoes.md:3` define como o mais destrutivo possível.

## A3 🟠 Quatro comportamentos de `FakeTimeProvider` que quebram o teste na primeira execução

Nada disso aparece, e todos são causa comum de teste vermelho ou pendurado:

1. **O relógio começa em 2000-01-01T00:00:00Z**, não em "agora" (construtor sem parâmetro). Código com sentinela de ano, com `DateTime.MinValue`, ou com validação "data não pode ser no passado" muda de comportamento.
2. **`SetUtcNow` lança `ArgumentOutOfRangeException` se o valor for anterior ao tempo atual do fake.** Não se volta no tempo com `SetUtcNow`; para isso existe `AdjustTime`, que — atenção — **não dispara timers**, enquanto `SetUtcNow`/`Advance` disparam.
3. **`GetLocalNow()` usa `LocalTimeZone` do provider, não o fuso da máquina**, e se ajusta com `SetLocalTimeZone`. Consequência de review: trocar `DateTime.Now` por `GetLocalNow()` **não corrige** o bug de fuso, só o torna testável. A recomendação correta na tabela é `GetUtcNow()` na regra, com conversão de fuso empurrada para a borda — que é literalmente a boa prática nº 2 da documentação oficial ("Use UTC time").
4. **`Advance` dispara timers de forma sincrônica na thread chamadora.** Em código `async`, continuações podem exigir um `await Task.Yield()` depois do `Advance` para rodar antes da asserção. É fonte clássica de teste intermitente — o que conecta com a lacuna C3.

## A4 🟠 "Injetar `Random` com seed fixa" tem dois defeitos, e um deles é bug de produção

**Onde:** `solid-smells.md:207` — "`Random` | Injetar `Random` com seed fixa no teste".

**Defeito 1, o oráculo não é estável.** A documentação de `System.Random` avisa, literalmente, que o exemplo de sequência reproduzível "may produce different sequences of random numbers if run on different versions of .NET". Ou seja: uma sequência fixada por seed é um oráculo que pode mudar num upgrade de runtime, **sem erro de compilação** — falha silenciosa, no CI, meses depois, longe da causa. Para teste de caracterização (o caso de uso do arquivo 2) isso é especialmente ruim.

**Defeito 2, e este é pior.** "Injetar `Random`" leva naturalmente a `AddSingleton<Random>`. A documentação é explícita: `Random` **não é thread-safe**, e se acessado concorrentemente sem sincronização "calls to methods that return random numbers **return 0**". Isto é, a seam recomendada para melhorar testabilidade introduz um defeito de concorrência silencioso em produção — e o `catalogo-patterns.md:97` já trata exatamente esse tipo de coisa como achado ("Thread safety interna obrigatória... Nunca `Dictionary`/`List` mutável cru").

**Correção.** A seam certa não é injetar `Random`, é injetar a *decisão*: uma abstração pequena (`IRandomSource` com `int Next(int, int)`) que no teste devolve valores canônicos, e em produção delega para `Random.Shared` (.NET 6+, thread-safe). Se por algum motivo quiser manter o tipo `Random`, ele é subclassável (`Next`, `NextDouble`, `Sample` são `virtual`) — herdar e sobrescrever é mais determinístico que confiar no algoritmo da seed.

## A5 🟠 A linha do `DbContext` está certa, mas achata a nuance que a própria Microsoft documenta

**Onde:** `solid-smells.md:203` — "`DbContext` concreto | Aceitável: `WebApplicationFactory` + Testcontainers testa melhor que mock".

O veredito está certo e alinhado com o time de EF Core. O que falta é o que o reviewer precisa para responder "então e quando não tem Docker?":

- **Mockar `DbContext` é razoável para comportamento que não é consulta.** A doc oficial diz que mockar `DbContext` "can be a good approach for testing various *non-query* functionality, such as calls to `Add` or `SaveChanges()`". O que é inviável é fingir *consulta* sobre `DbSet`, porque LINQ são métodos de extensão estáticos sobre `IQueryable` e a avaliação passa a ser em memória. A linha como está proíbe as duas coisas.
- **O ranking oficial de test doubles**, quando um é necessário: repository layer > SQLite in-memory > (bem atrás) provider in-memory. O `Microsoft.EntityFrameworkCore.InMemory` é "**highly discouraged**", não recebe features novas, não suporta transação nem SQL bruto. Isso merece uma linha própria, porque é o erro mais comum do mercado .NET e a tabela de seams é o lugar onde alguém iria procurar.
- **`WebApplicationFactory` + Testcontainers não dá isolamento entre testes por si só.** Falta o reset de estado (`Respawn`, transação com rollback, ou banco por classe). Sem isso, a recomendação entrega testes que passam sozinhos e falham em suíte — ver C3 e C8.

## A6 🟠 `WebApplicationFactory`: dois fatos que fazem a recomendação falhar na primeira tentativa

Ambos confirmados na documentação oficial de integration tests:

1. **`WebApplicationFactory<Program>` não compila com top-level statements.** A classe `Program` gerada é `internal`. É preciso `<InternalsVisibleTo Include="MeuProjetoDeTeste" />` no csproj do app, ou declarar `public partial class Program { }` no `Program.cs`. Não é detalhe cosmético: é a primeira coisa que trava quem segue a recomendação.
2. **Substituir registro de serviço tem ponto de extensão próprio.** Use `ConfigureTestServices` (dentro de `ConfigureWebHost`, ou via `WithWebHostBuilder` para escopar a substituição a um teste específico). E para trocar o `DbContext` não basta registrar outro: é preciso **remover** o registro existente, incluindo `DbContextOptions<T>`, senão sobra configuração do app.

Como a skill é de code review e não de scaffolding, basta uma nota de duas linhas — mas ela evita que o reviewer recomende algo que o autor não consegue rodar.

## A7 🟡 Testcontainers sem pré-requisito declarado

Falta o que determina se a recomendação é viável na empresa:

- **Exige daemon Docker** na máquina e no agente de CI. É a razão nº 1 pela qual essa recomendação é rejeitada em ambiente corporativo.
- **A imagem oficial do SQL Server é Linux-only.** Agente de CI com Windows containers não roda.
- **Ciclo de vida:** `IAsyncLifetime`; e em **xUnit v3 o `IAsyncLifetime` devolve `ValueTask`**, não `Task` como na v2 — é a quebra mais comum de migração.
- **Compartilhar um container entre classes** exige `ICollectionFixture` + `[Collection]`, senão sobem N containers e/ou os testes disputam o mesmo banco.

## A8 ✅ Nomenclatura de Feathers: todas as seis técnicas estão corretas

Verificação positiva, porque a skill vende esse vocabulário e um nome errado custaria credibilidade:

| No documento | Origem em *WELC* | Veredito |
|---|---|---|
| Sprout Method | cap. 6 | correto |
| Sprout Class | cap. 6 | correto |
| Wrap Method | cap. 6 | correto |
| Extract and Override Call | cap. 25 | correto |
| Parameterize Constructor | cap. 25 | correto |
| Break Out Method Object | cap. 25 | correto |

Duas observações menores:

- Faltam as duas irmãs de "Extract and Override Call", que resolvem casos que o documento não cobre: **Extract and Override Factory Method** (para `new` de dependência *dentro* do método) e **Extract and Override Getter** (para campo inicializado sob demanda). São as técnicas que o leitor vai precisar cinco minutos depois.
- `designpatterns-legacy/SKILL.md:78` abrevia para "Extract and Override" e "parametrizar construtor", perdendo o nome canônico. Se o valor é o vocabulário compartilhado, vale manter exato.

## A9 🟡 O método "sprouted" como `internal static` não é visível ao projeto de teste

**Onde:** `refatorar-sem-testes.md:59` — `internal static void AplicarDescontoFidelidade(...)`, com o comentário "novo, pequeno, sem dependência, **testável isoladamente**".

Como está, não é: `internal` não atravessa fronteira de assembly sem `[assembly: InternalsVisibleTo("Projeto.Tests")]`. Em projeto legado no formato antigo isso vai no `AssemblyInfo.cs` (o item MSBuild `<InternalsVisibleTo>` não existe lá) — detalhe que vale explicitar, já que `designpatterns-legacy/SKILL.md:3` usa `AssemblyInfo.cs` como sinal de legado.

## A10 🟡 Test Data Builder: afirmação verdadeira, mas subespecificada

**Onde:** `catalogo-patterns.md:79` — "Melhor uso prático: Test Data Builder. Reduz drasticamente o custo de manter dezenas de testes quando o construtor da entidade muda."

A afirmação está correta. Faltam quatro coisas, e três delas são armadilhas:

1. **Tensão com `required`.** A mesma ficha recomenda `required` + `init` (l. 78) como alternativa ao Builder. Mas um builder que carrega estado parcial não consegue segurar um objeto com membros `required` a meio caminho — a construção só acontece no `Build()`, com inicializador de objeto. Não é bloqueio, é uma linha de esclarecimento que evita o leitor tentar o híbrido errado.
2. **`with` de `record` costuma ser mais barato que um builder.** A própria ficha de Prototype (l. 105) já estabelece `with` como Prototype nativo. Um `static readonly Pedido Padrao = new() {...}` mais `Padrao with { Total = 500 }` entrega o benefício de Test Data Builder sem classe nova. Deveria ser o "quando NÃO" do Test Data Builder.
3. **Builder com defaults válidos esconde de que campo o teste realmente depende**, e faz teste passar por causa do default e não do código sob teste. Mitigação: defaults distintos e rastreáveis, e o teste setando explicitamente só o que importa para a asserção.
4. **Builder mutável compartilhado é contaminação entre testes.** Um builder guardado em `static`/`MemberData` e reusado quebra sob paralelismo do xUnit. O builder deve devolver nova instância a cada `With...`. Conecta com C3.
5. Não há menção a **AutoFixture** nem **Bogus**, que são o padrão de fato em .NET para dado de teste — chama atenção porque a mesma ficha lista cinco builders do framework em "Pronto no .NET".

---

# (b) CONSELHO PERIGOSO

## B1 🔴 O procedimento de teste de caracterização produz rede falsa em quatro cenários

**Onde:** `refatorar-sem-testes.md:27-35`. O procedimento (escreva o teste → asserção obviamente errada → rode → pegue o valor real → repita para bordas) é a técnica de Feathers e está correto na intenção. As quatro falhas:

### B1.1 O passo 2 pode passar por acidente, e o texto não manda verificar

`Assert.AreEqual(0, resultado)` como "valor obviamente errado" — só que método legado devolve `0`, `null`, `string.Empty` ou lista vazia com muita frequência, legitimamente. Se o teste **passa**, o leitor não aprendeu nada e segue acreditando que caracterizou.

Correção: escolha uma sentinela que não possa ser correta, e trate **"o primeiro run tem que falhar"** como parte do procedimento. Se não falhou, o resultado é informação (o valor é a sentinela) — confirme, não assuma. Relacionado: se o método **lança**, a asserção nunca executa e você não caracterizou nada; a exceção também precisa ser caracterizada (tipo e, se importar, mensagem).

### B1.2 Nunca manda rodar mais de uma vez, nem em outra máquina — e é assim que se fixa um baseline instável

O valor observado em legado depende com frequência de: `DateTime.Now`, `CultureInfo.CurrentCulture` (separador decimal, `decimal.Parse`), fuso da máquina, estado do banco, valor de coluna identity, `Guid.NewGuid()`, ordem de enumeração de `Dictionary`/hash, e **`SELECT` sem `ORDER BY`**. Fixar a partir de uma única execução fixa um baseline **flaky**, e o refactor da Fase 3 leva a culpa por uma falha que o baseline causou. Isso é pior que não ter teste, porque destrói a confiança na rede exatamente no momento em que ela é necessária.

Mínimo a acrescentar ao procedimento: rode 3x local, 1x no CI, e 1x com `CurrentCulture`/fuso alterados, **antes** de confiar no valor fixado. O próprio arquivo já sabe disso — a checklist final (l. 182) pergunta "o comportamento depende de cultura, fuso, ou de configuração de servidor?" — mas a pergunta está no fim do arquivo e desconectada do procedimento que ela deveria governar.

### B1.3 Copiar o valor da mensagem de falha pode copiar um valor que não é o valor real

- **Em .NET Framework 4.x, `double.ToString()` usa "G15" por padrão e não faz round-trip.** O número impresso na mensagem de falha **não é** o número que o código produziu. (Em .NET Core 3.0+ o `ToString()` passou a ser o menor round-trippable, então o problema é específico do alvo legado — que é justamente o alvo deste arquivo.)
- `float`/`double` exigem tolerância, nunca igualdade exata: MSTest `Assert.AreEqual(esperado, real, delta)`, NUnit `Is.EqualTo(x).Within(tol)`.
- `decimal` compara igual ignorando escala (`1.5m == 1.50m`), mas **renderiza diferente** — então uma asserção numérica e uma asserção de string/snapshot sobre o mesmo valor podem discordar.

### B1.4 Caracteriza só o valor de retorno, quando em legado o que importa é o efeito colateral

Esta é a omissão mais importante do arquivo. Método legado tipicamente grava linha, dispara e-mail, escreve arquivo, publica mensagem, mexe em `Session`. Uma suíte que fixa apenas o retorno passa **verde** por um refactor que parou de gravar a linha de auditoria.

Feathers chama isso de *sensing*: você precisa de um fake/spy no limite, com asserção sobre as chamadas registradas, mais asserção sobre o estado do banco. Sem essa metade, o procedimento cobre a minoria dos casos que o arquivo se propõe a resolver.

### B1.5 (menor) Falta marcar o teste como caracterização no código

O arquivo acerta ao mandar registrar o comportamento estranho como pergunta ao negócio (l. 37), mas isso fica no PR ou na cabeça de alguém. Em 18 meses, um teste chamado `CalcularJuros_Retorna_37_45` é lido como especificação. Marque com trait/categoria (`[Trait("Tipo","Caracterizacao")]`, `[TestCategory("Caracterizacao")]`) e ponha a dúvida como comentário no teste, onde ela será lida.

## B2 🔴 Sprout Method: "o risco de regressão fica limitado a uma linha" é falso

**Onde:** `refatorar-sem-testes.md:66`.

O método sprouted pode estar 100% coberto. O **ponto de inserção** está 0% coberto, e é lá que mora todo o risco:

- `pedido.Total` já está calculado nesse ponto das 300 linhas, ou ainda é zero?
- Alguma coisa depois sobrescreve `pedido.Desconto`?
- A linha caiu dentro de um `for`, de um `try`, de uma transação?
- Existe `return`/`continue` antes que faz a linha nunca executar em certos caminhos?

O exemplo agrava isso ao **mutar o parâmetro** (`pedido.Desconto = ...`), o que maximiza a sensibilidade à ordem. Feathers é explícito que o ponto de inserção do sprout permanece não testado.

**Enquadramento correto:** Sprout Method limita o *raio de dano de um defeito no código novo*. Não limita o *risco de integração*. São coisas diferentes, e a frase atual autoriza aprovar o PR sem olhar o ponto de inserção.

**Correção concreta no exemplo:** prefira sprout que **devolve valor**, e a linha legada atribui:

```csharp
pedido.Desconto = CalcularDescontoFidelidade(pedido);   // <- a única linha adicionada

internal static decimal CalcularDescontoFidelidade(Pedido pedido)
{
    return pedido.Cliente.AnosDeRelacionamento >= 5
        ? pedido.Total * 0.05m
        : 0m;
}
```

Função pura, trivial de testar, e o diff é uma atribuição — mais fácil de revisar do que um efeito colateral escondido numa chamada `void`.

## B3 🔴 Extract and Override Call: "risco praticamente zero" ignora três armadilhas reais

**Onde:** `refatorar-sem-testes.md:95` ("sem mudar assinatura"), l. 123 ("risco praticamente zero"), l. 153 ("Risco praticamente nulo").

### B3.1 Método `virtual` alcançável pelo construtor devolve `default` na subclasse de teste

Se o construtor da base chamar (hoje ou depois) o novo método `virtual`, o campo `_fixa` de `RelatorioServiceTestavel` **ainda não foi atribuído** — o construtor da base roda antes do da derivada. `ObterDataAtual()` devolve `default(DateTime)` = `0001-01-01`, e você fixa um valor sem sentido num teste de caracterização, achando que fixou a regra. O compilador não avisa; só analisadores (CA2214 / S1699), que em legado normalmente estão desligados.

O exemplo do arquivo está a um refactor de distância disso. Regra a acrescentar: nunca mova para membro `virtual` uma chamada alcançável pelo caminho do construtor; nesse caso use *Supersede Instance Variable* ou passe o valor.

### B3.2 Exige destravar a classe e cria ponto de extensão público permanente

`protected virtual` é superfície de API. A classe precisa deixar de ser `sealed`, e a partir daí qualquer subclasse — inclusive fora da solução, se a biblioteca é compartilhada — pode sobrescrever o relógio. É um compromisso de compatibilidade assumido pela conveniência de um teste. Vale, mas tem que ser dito, principalmente porque `SKILL.md:81` já estabelece cuidado com assinatura pública de biblioteca compartilhada.

### B3.3 Você deixa de testar o tipo de produção

`RelatorioServiceTestavel` é outro tipo. Qualquer comportamento acidental nele (um inicializador de campo, um segundo override acrescentado meses depois) divergiu de produção sem ninguém notar. Aceitável como passo transitório — e o arquivo acerta ao dizer que o passo seguinte é trocar por `IClock` injetado (l. 123) — mas o risco precisa de nome, não de "praticamente zero".

### B3.4 O próprio exemplo é sensível a fuso e trunca dias

`DateTime.Now` (local, sujeito a horário de verão) e `(hoje - contrato.Vencimento).Days` — `.Days` descarta 23h59m, e a subtração de `DateTime` local atravessando mudança de horário de verão não é o número de dias de calendário. Um teste de caracterização escrito em volta disso fixa um valor dependente de fuso, que é exatamente o modo de falha B1.2. Trocar por `DateTimeOffset`/UTC no mesmo passo seria mudar comportamento (proibido pela regra 1 da própria skill), então o certo é **fixar e marcar como pergunta ao negócio** — mas o exemplo deveria dizer isso, já que é o exemplo-vitrine da técnica.

## B4 🟠 Wrap Method: "Nenhum chamador muda" vale para a compilação, não para o comportamento

**Onde:** `refatorar-sem-testes.md:91`.

### B4.1 O caminho de falha mudou

Antes, `Salvar` bem-sucedido era a operação inteira. Depois:

- Se `RegistrarAuditoria` lançar, o chamador vê **falha depois do save ter acontecido** — um estado de sucesso parcial que não existia.
- Se `SalvarOriginal` lançar, a auditoria nunca ocorre.

Ordem, escopo transacional e política de erro do novo comportamento passaram a ser decisões de design, e o snippet as toma implicitamente. Em código que grava dinheiro isso é achado 🔴, não detalhe.

### B4.2 Se o método original era `virtual`, `override` ou implementação de interface, renomear não é neutro

Subclasses existentes sobrescrevem `Salvar`. Depois do wrap, o override substitui o **wrapper** e **pula a auditoria silenciosamente** — regressão de comportamento que compila limpa. O mesmo vale para implementação explícita de interface.

### B4.3 Wrap Method **é** um rename, e o arquivo tem uma checklist sobre rename que não é referenciada aqui

As linhas 174 e 178 avisam sobre reflection, binding por string, serialização e injeção por nome. Wrap Method renomeia um método público. Em WebForms/MVC5 isso morde forte: `OnClick="Salvar"` no markup `.aspx`, `[WebMethod]` em ASMX, `[OperationContract]` em WCF, binding de nome de action. A seção deveria apontar explicitamente para a checklist do fim do arquivo.

## B5 🟠 Parameterize Constructor: "Nenhum chamador quebra" ignora container e serializador

**Onde:** `refatorar-sem-testes.md:127`.

- **Container escolhe construtor.** O DI da Microsoft / `ActivatorUtilities` seleciona pelo que consegue satisfazer; com dois candidatos, qual roda pode mudar silenciosamente, ou dar `InvalidOperationException` por ambiguidade. Os containers legados que a própria SKILL.md lista (Unity, Windsor, StructureMap, Ninject) têm regras próprias de "greediest resolvable" — registrar `ISefazGateway` depois pode inverter qual construtor é usado, e a falha aparece em runtime, longe da mudança (que é exatamente o erro listado na l. 173 do próprio arquivo).
- **Serializador quebra com dois construtores.** `System.Text.Json` lança quando há múltiplos construtores públicos parametrizados sem `[JsonConstructor]`; Newtonsoft escolhe por outra regra; `XmlSerializer`, WebForms e WCF precisam que o sem-parâmetro continue existindo.
- **O construtor antigo mantém o caminho não testado vivo para sempre.** `new NotaFiscalService()` continua instanciando o `SefazGateway` real (e possivelmente abrindo conexão) com zero cobertura, e ninguém percebe. A regra 5 da própria `SKILL.md:81` diz o que fazer: marque com `[Obsolete("Use a sobrecarga que recebe ISefazGateway")]` **no mesmo commit**, e remova quando os chamadores migrarem.

## B6 🟠 Break Out Method Object é apresentado como mecânico, e não é

**Onde:** `refatorar-sem-testes.md:145-147`.

- **Risco de sombreamento (o mais perigoso, e invisível ao compilador).** Ao promover locais a campos, se o método gigante declara um local com o mesmo nome de um campo promovido — ou a classe já tem campo com esse nome — o código **continua compilando** e passa a ler/escrever outro local de armazenamento. É o jeito clássico de esse refactor introduzir bug silencioso.
- **O objeto resultante é mutável, com estado e de uso único.** Se alguém registrar no container ou reusar a instância, não é reentrante nem thread-safe. Tem que estar escrito: uma instância por invocação.
- **Não é mecânico na presença de** `ref`/`out`, `goto`, `yield return`, closures capturando locais, e locais declarados dentro de `try` com escopo diferente.
- **Fase errada.** O plano faseado (l. 153-159) coloca "seam" na Fase 1 com "risco praticamente nulo" e o teste na Fase 2. Break Out Method Object **move o corpo do método** e por isso pertence à Fase 3, *depois* da rede — não à lista de técnicas de baixo risco. Faça pelo refactor "Extract Class" da IDE, em commit isolado, sem nenhuma outra mudança.

## B7 🟠 Falta um ranking explícito de risco entre as seis técnicas

Estão numa lista plana sob a mesma promessa ("acrescentar em volta em vez de reescrever dentro"), e a seção de ordem recomendada (l. 153) só nomeia duas. Sem escala, o leitor escolhe pelo exemplo mais bonito. Escada sugerida, risco crescente:

| Técnica | Risco | O que vigiar |
|---|---|---|
| Sprout Method / Sprout Class | mais baixo | ponto de inserção (B2) |
| Parameterize Constructor | baixo | container e serializador (B5) |
| Extract and Override Call | médio | chamada no construtor, unsealing (B3) |
| Wrap Method | médio-alto | override existente, binding por string (B4) |
| Break Out Method Object | alto, exige teste antes | sombreamento de nome (B6) |

## B8 🟡 "Parar depois da fase 2 já é lucro" precisa de ressalva de manutenção

**Onde:** `refatorar-sem-testes.md:161`. O conselho está certo e é valioso. A ressalva: uma suíte de caracterização sem dono, com valores fixados e sem intenção documentada, em 18 meses vira parede vermelha que o próximo time apaga inteira — e aí o lucro virou prejuízo. Acrescente: nome do teste descreve o comportamento, a dúvida vira trait + comentário (B1.5), e o PR registra quais valores são suspeitos de bug.

---

# (c) LACUNAS CRÍTICAS

## C1 🔴 A skill não tem estratégia de teste em lugar nenhum

São 14 arquivos. Teste aparece em três lugares: uma tabela de 10 linhas de seams, um arquivo de legado, e uma linha sobre Test Data Builder. Não existe resposta para **"quanto de qual tipo"**.

Isso importa numa skill de code review porque "faltam testes" é um dos achados mais frequentes que um reviewer escreve, e sem uma forma-alvo a recomendar o achado degenera em "adicione mais testes", que é inacionável.

O que falta:

- **Pirâmide vs. *test trophy*, com a posição assumida.** Para API ASP.NET Core, a camada de maior valor por unidade de esforço normalmente é o teste de integração via `WebApplicationFactory` contra banco real — o que **contraria** a leitura ingênua da pirâmide e por isso precisa ser dito em voz alta, com o motivo (roteamento, model binding, política de autorização, tradução LINQ, migração, transação e concorrência só existem ali).
- **A divisão de trabalho.** Unitário: regra pura de domínio, value object, cálculo, máquina de estados. Integração: tudo que atravessa fronteira. Não é orçamento a dividir, são complementos.
- **Onde o teste de UI/E2E entra** (pouquíssimos, só caminhos de dinheiro) e por quê.

## C2 🔴 O único critério de review sobre teste contradiz a própria tabela — e o scoring premia o lado errado

Três lugares em conflito:

| Onde | Diz |
|---|---|
| `solid-smells.md:203` | testar `DbContext` via `WebApplicationFactory` + Testcontainers "testa melhor que mock" |
| `solid-smells.md:209` | "se a única forma de testar uma regra de negócio é subindo infraestrutura, isso é um achado 🟠" |
| `scoring.md:79-81` | **9-10** = "toda regra testável por construtor, **sem infraestrutura**"; **7-8** = "um ponto **exige** teste de integração"; **5-6** = "teste exige subir banco ou `WebApplicationFactory`" |

O scoring **penaliza numericamente** a necessidade de teste de integração. Ou seja: a doutrina operacionalizada na nota diz o oposto da tabela de seams, e o oposto da recomendação oficial do time de EF Core. Um reviewer LLM lendo os dois vai produzir achados contraditórios no mesmo PR, e vai baixar a nota de um código que fez a coisa certa.

**Correção mínima:**

1. Escopar a l. 209 a regras que **não** precisam intrinsecamente de infraestrutura (cálculo de desconto, validação, transição de status). Uma regra que depende de comportamento do banco não é violação de testabilidade.
2. Acrescentar a regra espelhada, que hoje não existe: *"regra validada apenas por unit test com repositório mockado, mas que depende de comportamento do banco (tradução LINQ, unicidade, concorrência, transação, colação), é achado 🟠 na direção oposta: falta teste de integração."*
3. Reescrever a régua de Testabilidade para medir **determinismo e isolamento de dependência**, não ausência de infraestrutura. "Exige teste de integração porque toca o banco" é design correto, não dívida.

## C3 🔴 Flakiness não é mencionada — e o arquivo legado é uma fábrica dela

O procedimento de caracterização (B1.2) fixa valores potencialmente instáveis, e nada no material trata do assunto. Falta:

- **As causas em .NET:** relógio real, fuso e cultura da máquina, banco compartilhado, dependência de ordem de execução, paralelismo contra fixture compartilhada, espera por `Task.Delay` em vez de polling com timeout, dado semeado com `DateTime.Now`, `SELECT` sem `ORDER BY`, estado estático mutável em `MemberData`/builder (A10.4).
- **A política:** teste intermitente é **defeito da suíte (🔴)**, não incômodo. Quarentena por trait, corrigir ou apagar. **Nunca** `[Retry]` — retry-to-green esconde exatamente a corrida que o teste encontrou, que é frequentemente o bug de produção.
- **A mecânica:** collections do xUnit e `ICollectionFixture` para estado compartilhado, `[Collection]` para serializar testes que tocam banco, `AssemblyFixture` na v3, `Respawn` para reset, `FakeTimeProvider` no lugar de relógio real (com a ressalva A3.4).

## C4 🔴 Teste de concorrência ausente — e os achados 🔴 de bandeira da skill dependem dele

`designpatterns-legacy/SKILL.md:66` e `smells-legado.md` tratam deadlock por sync-over-async como achado de primeira linha; `catalogo-patterns.md:97-99` trata thread-safety de singleton e captive dependency como achado. Nada diz **como verificar**. Falta:

- **N requisições em paralelo** (`Task.WhenAll` sobre o mesmo `HttpClient` de `WebApplicationFactory`) para exercitar corrida no caminho de request.
- **Dois `DbContext` concorrentes** para provar que o token de concorrência otimista (`RowVersion`) ou o índice único realmente disparam. Isso é **impossível contra fake** — é o caso concreto em que só o banco real serve, e é o argumento mais forte a favor da linha 203 da tabela de seams.
- **Loop sob contenção** para singleton com estado mutável (inclusive o `Random` de A4.2).
- **O ponto não óbvio, e o mais importante para legado:** o deadlock de `.Result`/`.Wait()` depende de haver `SynchronizationContext`. Num teste xUnit/console **não há**, então **o deadlock não reproduz e o teste passa**. Para demonstrá-lo é preciso rodar sob um contexto real (`Nito.AsyncEx.AsyncContext`, ou o contexto do ASP.NET clássico). Ou seja: o achado-vitrine da skill legada é justamente o que um teste ingênuo não consegue mostrar — e isso precisa estar escrito, senão o autor "prova" que não tem problema.

## C5 🔴 Snapshot testing ausente, e é exatamente a ferramenta do problema central do arquivo legado

O laço manual de B1 ("rode, leia o valor, cole na asserção") não escala além de um escalar. O código legado que chega para review devolve `DataTable` de 40 colunas, XML de NF-e, HTML de relatório, grafo de DTO.

**`Verify` (VerifyTests) automatiza o procedimento inteiro:** a primeira execução escreve `*.received.*`, você revisa e aprova para `*.verified.*`, que é comitado como baseline. Isso **é** um teste de caracterização — com ferramenta de diff em vez de copiar-e-colar, e com *scrubbers* para justamente os campos não determinísticos (datas, GUIDs, nome de máquina, caminhos) que causam B1.2. Tem adaptadores para xUnit, NUnit e MSTest, e `ApprovalTests.Net` é o irmão mais velho que roda em .NET Framework 4.x.

Segundo uso que vale nomear: **snapshot da superfície pública** (`PublicApiGenerator` + Verify) transforma "meu refactor mudou o contrato?" em diff revisável — servindo diretamente a regra 5 da `SKILL.md:81` sobre não alterar assinatura pública.

A ausência disso é a maior lacuna de ferramenta do arquivo 2, porque é a ferramenta que resolve o problema que o arquivo passa 35 linhas descrevendo à mão.

## C6 🟠 Mutation testing ausente, e é a única resposta honesta a "minha rede é real?"

Uma suíte construída colando valores observados é especialmente propensa a ser *com cara de asserção e vazia de conteúdo*: fixa um valor que qualquer mudança reproduz, ou fixa o `null` que um `catch` vazio devolveu. Cobertura não detecta isso.

**`Stryker.NET`** (`dotnet-stryker`) muta o código e reporta quais mutantes a suíte mata. Num método legado, é o jeito mais rápido de descobrir que 90% de cobertura corresponde a 30% de mutation score. Recomendar escopado à classe que está para ser refatorada (`--mutate`), não na solução inteira, porque tempo de execução é a objeção padrão.

## C7 🔴 Cobertura como métrica enganosa não é tratada, e a skill dá nota

Pontos que precisam estar escritos:

- **Cobertura de linha conta linha executada, não comportamento verificado.** Um teste de caracterização com asserção fraca — ou sem asserção — produz cobertura cheia e proteção zero. Isso não é hipótese: é o produto natural do procedimento B1.1 quando o passo 2 passa por acidente.
- **Branch coverage é o mínimo útil**, e mesmo ela não cobre condição: `a && b` pode ter 100% de branch sem exercitar os dois operandos.
- **Meta de cobertura produz teste de getter e de `ToString()`.** Previsivelmente.
- **Os dois usos legítimos:** (i) cobertura **no diff**, como localizador de lacuna *antes* do refactor — "quais branches deste método a minha caracterização ainda não alcança", que é a resposta certa para o vago "casos de borda que você conseguir alcançar" da l. 33; (ii) **mutation score** como número de qualidade, não cobertura.
- **Ferramenta:** `coverlet.collector` + `ReportGenerator`; `dotnet test --coverage` via Microsoft.Testing.Platform no .NET moderno. Em projeto legado não-SDK, coverlet geralmente não funciona — AltCover, dotCover, ou OpenCover (sem manutenção).

## C8 🔴 "Como testar legado que depende de banco" é a maior lacuna prática, e é o caso mais comum

As seams do arquivo 2 cobrem relógio, gateway e construtor. **Nunca o banco** — embora regra de negócio legada tipicamente esteja *dentro* do SQL ou em ADO.NET inline. O que falta:

**1. Escolher o nível da seam.**
- SQL em string dentro do método → a seam honesta é a *conexão/comando*: `IDbConnectionFactory` ou uma classe gateway fina é o menor passo.
- Lógica dentro de procedure ou trigger → **não existe seam em C#**. A única caracterização possível é contra banco real. Este é o caso em que "faltam testes unitários" é o achado errado, e a skill precisa dizer isso para o reviewer não pedir o impossível.

**2. Estratégia de isolamento, com o modo de falha de cada uma:**

| Estratégia | Velocidade | Quebra quando |
|---|---|---|
| Transação com rollback por teste | mais rápida | o SUT abre a própria conexão, comita internamente, ou usa `TransactionScope`/MSDTC — e aí **para de isolar silenciosamente** |
| `Respawn` (reset entre testes) | média | quase nunca; funciona com qualquer acesso a dados |
| Banco/schema por classe de teste | mais lenta | custo de provisionamento |

**3. Provisionamento de schema:** DACPAC/SSDT publish, DbUp, migrations do EF, ou restore de backup sanitizado — com seed determinístico, e **não** um banco de desenvolvimento compartilhado, que é a origem mais comum da flakiness de C3.

**4. Não determinismo dentro do próprio banco**, que sabota caracterização: `GETDATE()`/`NEWID()` em procedure e trigger, valor de identity/sequence dentro da asserção, colação e case-sensitivity, opções `SET` no nível da conexão, `SET DATEFIRST`/`DATEFORMAT`, e query sem `ORDER BY`. A checklist do arquivo (l. 181) pergunta "existe procedure ou trigger que replica essa regra?" e nunca diz o que fazer com a resposta.

**5. Realidade de ambiente:** Testcontainers exige daemon Docker; a imagem oficial do SQL Server é Linux-only; muita empresa tem CI com Windows containers ou sem Docker. Fallbacks a nomear: SQL Server LocalDB, instância compartilhada com schema por desenvolvedor, e estágio de integração noturno separado do CI de PR.

## C9 🟠 Falta a técnica de maior valor para refatorar cálculo sem teste: execução em paralelo e comparação

Para um cálculo de dinheiro, juros ou imposto sem teste — o caso de maior risco que a skill legada existe para servir — o passo mais seguro **não** é "caracterize cinco casos de borda e confie". É:

1. Manter a implementação antiga.
2. Colocar a nova atrás da mesma abstração (é assim que Wrap Method se torna útil de verdade).
3. Rodar as duas em toda chamada real (ou sobre replay de entradas históricas), devolvendo sempre o resultado da antiga.
4. Logar divergências.
5. Trocar só quando a divergência for zero sobre volume significativo.

Isso substitui "espero que meus cinco casos representem 10 anos de dados" por evidência da distribuição real. `Scientist.NET` implementa o padrão; um wrapper de comparação na mão tem 20 linhas. Pertence ao plano faseado como **Fase 3 alternativa para cálculo de alto risco**, e é a resposta certa quando a checklist da l. 181 revela que existe procedure replicando a regra.

## C10 🟠 Falta rede de segurança para desempenho e para contrato serializado

Duas coisas que um refactor "comprovadamente neutro" quebra com toda a caracterização verde:

- **Desempenho.** Trocar laço manual por LINQ, ou `switch` por Strategy com resolução no container, muda alocação e latência em caminho quente. `BenchmarkDotNet` (roda em `net472`) antes/depois é a única verificação honesta, e é o companheiro natural das recomendações de Object Pool e caminho quente do `catalogo-patterns.md:108-113`.
- **Contrato serializado.** Transformar DTO em `record`, reordenar membros ou renomear propriedade muda o JSON/XML para consumidores que não estão na solução. Snapshot sobre o payload serializado pega isso; a checklist do arquivo (l. 179) se preocupa com o consumidor e não oferece o teste.

## C11 🟡 Nenhuma convenção de autoria de teste

Não há AAA, nem esquema de nomes, nem "um conceito por teste", nem "asserte comportamento, não implementação". Duas ausências com impacto direto no tema da skill:

- **Asserção sobre contagem de chamada de mock em consulta** (`Verify(x => x.Get(...), Times.Once)`) acopla o teste à implementação e vai brigar com todo refactor. Numa skill sobre refatorar, isso merece linha própria: mock para *comando* (verificar que gravou/enviou), stub para *consulta*.
- **`[Theory]`/`[TestCase]` para caracterização.** O trabalho é naturalmente tabelar: uma linha de theory por caso fixado é muito mais manutenível que cinco testes copiados. É uma melhoria barata e concreta ao passo 5 (l. 33).

## C12 🟡 Licenciamento de biblioteca de teste não aparece, e o kit tem uma skill que trata disso

Recomendar biblioteca sem checar licença cria problema de compra num cliente corporativo:

- **FluentAssertions v8 passou a licença comercial** (Xceed). Alternativas drop-in: `AwesomeAssertions` (fork da comunidade da linha 7) e `Shouldly`.
- **Moq 4.20.0 (episódio SponsorLink)** deixou muitas empresas fixadas abaixo dessa versão ou migradas para `NSubstitute`/`FakeItEasy`.

---

# (d) LEGADO: .NET Framework 4.x com MSTest ou NUnit antigo

## D1 🔴 O erro de fato mais consequente para legado é o A1

Escada de decisão que deveria substituir "`TimeProvider` não existe":

| Alvo | Recomendação |
|---|---|
| `net472+` com `PackageReference` | `Microsoft.Bcl.TimeProvider` + `Microsoft.Extensions.TimeProvider.Testing`. Mesma abstração da skill moderna, uma divergência a menos entre as duas |
| `net462`-`net471` | mesmos pacotes, funcionam; avisos de binding possíveis (a própria `restricoes-versoes.md:85` já explica por quê) |
| `net45x`-`net461`, ou `packages.config` | `IClock` na mão — **e este é o motivo real a declarar** |

## D2 🔴 O runner e o formato do projeto são o bloqueio real, e não são mencionados

Todo o arquivo 2 pressupõe que se consegue escrever e rodar um teste. Em `.csproj` clássico com `packages.config`:

- **`dotnet test` não funciona.** É `msbuild` + `vstest.console.exe`, ou o console runner do NUnit/xUnit. Qualquer instrução de CI que diga `dotnet test` falha.
- **`coverlet` na prática exige projeto SDK-style** → AltCover, dotCover, OpenCover.
- **`<InternalsVisibleTo>` como item MSBuild não existe** → vai em `AssemblyInfo.cs` (relevante para A9).
- **Central package management e resolução transitiva moderna não existem.**

**Recomendação que o arquivo deveria fazer, e é de altíssimo retorno:** migrar **só o projeto de teste** para SDK-style com `PackageReference`. Ele continua com alvo `net472` e continua referenciando os projetos antigos. Esse único passo destrava `dotnet test`, coverlet, Testcontainers, `Verify` e bibliotecas de asserção modernas **sem tocar no csproj de produção**.

Vale ainda o enquadramento de venda: **criar projeto de teste novo não é mudança em código de produção**, portanto não carrega nenhum dos riscos que o arquivo gasta 180 linhas administrando. É a Fase 0 óbvia e está faltando.

## D3 🔴 Falta a ferramenta que resolve o problema central do legado sem seam nenhuma: Microsoft Fakes (Shims)

A premissa do arquivo (l. 9) é "sem seam não existe teste unitário". Em .NET Framework isso **não é estritamente verdade**: interceptação via API de profiler substitui `DateTime.Now`, estáticos, tipos `sealed`, membros não virtuais e construtores **sem nenhuma alteração no código de produção**.

- **Microsoft Fakes / Shims** — vem no Visual Studio Enterprise, é a resposta canônica em `net4x`. `ShimDateTime.NowGet = () => dataFixa;` dentro de um `ShimsContext` elimina a necessidade de Extract and Override para relógio e I/O.
- **Telerik JustMock** e **TypeMock Isolator** — comerciais, fazem o mesmo fora do VS Enterprise.

Trade-offs a declarar honestamente: custo de licença / porta de entrada VS Enterprise; teste mais lento e obrigado a rodar sob o profiler (exige configuração de CI); geração de Fakes infla o build; e o risco de congelar um design intestável em vez de melhorá-lo.

**Posicionamento correto:** use para **comprar a primeira rede** em código que você não pode tocar, e então use essa rede para introduzir a seam de verdade e apagar o shim. É a filosofia de dois passos da própria l. 123, aplicada um nível antes.

Esta é a maior lacuna de legado do material, porque muda a resposta nos casos mais difíceis: code-behind de WebForms, manager estático, tipo `sealed` de terceiro, `HttpContext.Current`.

## D4 🟠 Seams que a plataforma `net4x` já oferece e o arquivo não nomeia

O arquivo dá tipos genéricos de seam, mas não os específicos que o `net4x` já entrega prontos — que são muito mais baratos que o conselho genérico:

| Obstáculo em `net4x` | Seam pronta |
|---|---|
| `HttpContext.Current` | `HttpContextBase`/`HttpContextWrapper` (`System.Web.Abstractions`). Em MVC5 o controller **já recebe** `HttpContextBase` — a seam muitas vezes já existe |
| `File.*`, `Directory.*` | `System.IO.Abstractions` (TestableIO), `netstandard2.0`, com `MockFileSystem` incluído. A skill manda criar `IFileSystem` na mão (`solid-smells.md:140`, `SKILL.md:98`) |
| `ConfigurationManager.AppSettings` | um `App.config` no projeto de teste fornece os valores **sem nenhuma mudança de código** — risco zero. (Mutar `AppSettings` em runtime lança, porque a coleção é read-only; então a rota do `App.config` é a prática) |
| WCF/ASMX/HTTP externo | Adapter no proxy (já recomendado em `SKILL.md:94`) + `WireMock.Net` (`netstandard2.0`) para fake em nível HTTP |
| `DbContext` do **EF6** | O EF6 tem construtor `DbContext(DbConnection, bool)` — **Parameterize Constructor se aplica diretamente ao contexto**, apontando para LocalDB ou container. E `Database.BeginTransaction()` suporta rollback por teste |
| EF6 "in-memory" | `Effort` existe, mas diverge do SQL Server pelos mesmos motivos do provider in-memory do EF Core — merece o mesmo desencorajamento |

## D5 🟠 Frameworks de teste antigos: o snippet do arquivo não compila em NUnit 4

O procedimento de caracterização escreve `Assert.AreEqual` literalmente (l. 32), então os detalhes de framework importam:

- **MSTest v1** (`Microsoft.VisualStudio.QualityTools.UnitTestFramework`, referência de GAC): sem `dotnet test`, sem suporte async utilizável, sem atributos data-driven decentes. Migrar para **MSTest v2** (`MSTest.TestFramework` + `MSTest.TestAdapter`), que é NuGet, suporta `net4x`, teste async e `[DataRow]`.
- **NUnit 2.x** está EOL. NUnit 3 suporta `net45+`; NUnit 4 exige `net462+`.
- **NUnit 4 removeu o modelo clássico de `Assert`:** `Assert.AreEqual` foi para `ClassicAssert` (namespace `NUnit.Framework.Legacy`); a forma suportada é `Assert.That(resultado, Is.EqualTo(0))`. **O snippet da l. 32 não compila em NUnit 4 como está.** Vale uma nota, porque o arquivo é escrupuloso quanto a "sintaxe que compila no alvo" (`restricoes-versoes.md:3`) e aqui escorregou no próprio critério.
- **xUnit** usa `Assert.Equal(esperado, real)`. **xUnit v3 suporta `net472+`**, então uma casa legada *pode* adotá-lo; mas projeto v3 é console app auto-executável (mudança real em relação à v2) e `IAsyncLifetime` devolve `ValueTask` (A7).
- **`async void` em método de teste passa silenciosamente** em todos os frameworks. Em código legado sendo convertido para async, é armadilha viva.
- **Ponto flutuante:** MSTest `Assert.AreEqual(double, double, delta)`; NUnit `Is.EqualTo(x).Within(tol)`. Necessário para B1.3.

## D6 🟠 Falta a tabela "o que do moderno realmente roda em `net4x`" — e o material subestima o que está disponível

`designpatterns-legacy/SKILL.md:68` diz que teste de integração é "geralmente indisponível" em legado. Isso é pessimista demais e custa valor ao review:

| Ferramenta | Roda em `net472`? | Observação |
|---|---|---|
| `WebApplicationFactory` | ❌ | só ASP.NET Core. **Mas:** `Microsoft.Owin.Testing.TestServer` para qualquer app com `Startup.cs`; `System.Web.Http.HttpServer` + `HttpClient` em memória para Web API 2 (teste de integração real, sem IIS). Para WebForms/MVC5 não há host em memória → IIS Express + teste HTTP, ou Playwright/Selenium nos poucos caminhos de dinheiro |
| **Testcontainers** | ✅ | pacote com alvo `netstandard2.0`. Contradiz "geralmente indisponível" — precisa de Docker, não de .NET moderno |
| `Verify` / `ApprovalTests.Net` | ✅ | `ApprovalTests.Net` é o nativo de `net4x` |
| `TimeProvider` / `FakeTimeProvider` | ✅ | ver A1/D1 |
| `System.IO.Abstractions`, `WireMock.Net`, `Respawn`, `Polly` | ✅ | todos `netstandard2.0`. `Respawn` é a ferramenta de isolamento para banco legado compartilhado (C8) |
| `BenchmarkDotNet` | ✅ | permite a rede de desempenho de C10 |
| `Stryker.NET` | ⚠️ | precisa de SDK moderno / projeto SDK-style. Trate como indisponível em csproj clássico — mais um motivo para D2 |
| `bUnit`, Minimal API testing, `Microsoft.Testing.Platform`, `dotnet test --coverage` | ❌ | |

## D7 ✅ Sintaxe dos exemplos respeita C# 7.3

Verificação positiva: os exemplos de `refatorar-sem-testes.md` usam apenas sintaxe compatível com C# 5 (tipos explícitos, construtores clássicos, sem expression-bodied member, sem `record`, sem `var` problemático, sem interpolação). Nenhum achado. Única observação: escrever o `InternalsVisibleTo` de A9 na forma de `AssemblyInfo.cs`, não como item MSBuild, para o leitor de legado.

---

# Prioridade de correção sugerida

| Prioridade | Achados | Esforço |
|---|---|---|
| 1 | **B1** (procedimento de caracterização: 4 falhas) e **B2/B3/B4/B5** (as três frases que minimizam risco) | reescrita de ~40 linhas no arquivo 2 |
| 2 | **A1/D1** (`TimeProvider` em `net4x`) e **C2** (contradição entre tabela de seams, regra 209 e régua de scoring) | correções pontuais, alto retorno |
| 3 | **C8** (testar legado com banco) e **C5** (snapshot/Verify como a ferramenta de caracterização) | seções novas; são as duas maiores lacunas de conteúdo |
| 4 | **D2/D3** (projeto de teste SDK-style como Fase 0; Microsoft Fakes) | seção nova no arquivo 2 |
| 5 | **C1/C3/C4/C6/C7** (estratégia, flakiness, concorrência, mutation, cobertura) | provavelmente um arquivo de referência novo, `estrategia-de-teste.md` |
| 6 | A2-A7, A9, A10, C9-C12, D4-D6 | ajustes de tabela e notas |
