# Modernização incremental

Leia apenas quando o usuário demonstrar interesse em migrar. Não empurre migração num review de rotina, porque migração é projeto com custo e risco, não recomendação de code review.

## Regra que evita desastre

**Nunca recomende reescrita completa.** A reescrita ("big rewrite") falha por um motivo estrutural: o sistema legado contém anos de decisões de casos de borda que ninguém documentou, e a reescrita precisa descobrir todas de novo, sob pressão, enquanto o sistema antigo continua evoluindo. Enquanto isso o negócio paga dois times e não recebe feature nova.

O caminho que funciona é **Strangler Fig**: o sistema novo cresce em volta do antigo, assumindo uma responsabilidade por vez, até o antigo poder ser desligado. Cada passo entrega valor e pode ser revertido.

## A escada de migração

Os degraus estão em ordem de risco crescente e podem parar em qualquer ponto. Vários deles entregam ganho real sem sair do .NET Framework, o que é a informação mais útil que você pode dar num review.

**Degrau 1, subir o target framework para `net472` ou `net48`.** Geralmente sem alteração de código. Destrava o consumo confortável de pacotes `netstandard2.0`, o que significa acesso a `Microsoft.Extensions.*`, `System.Text.Json`, `Polly` e `IHttpClientFactory` sem sair da plataforma. Melhor relação custo-benefício de toda a escada.

**Degrau 2, migrar `packages.config` para `PackageReference`.** Simplifica o `.csproj`, resolve conflito de dependência transitiva, e é pré-requisito prático para os degraus seguintes. O Visual Studio tem migração automática, mas verifique pacotes com `install.ps1`, que não funcionam em `PackageReference`.

**Degrau 3, converter o `.csproj` para o formato SDK.** Ainda com alvo `net48`. Elimina a lista manual de arquivos, permite `<LangVersion>`, e torna o projeto multi-target no futuro. Cuidado com `AssemblyInfo.cs` duplicado e com arquivos de conteúdo que precisam de declaração explícita.

**Degrau 4, extrair a regra de negócio para bibliotecas `netstandard2.0`.** Este é o degrau que realmente prepara a migração. A regra sai dos projetos web e vai para bibliotecas que **tanto** o `net48` **quanto** o .NET moderno conseguem referenciar. O que impede uma classe de ir para `netstandard2.0` é exatamente o que precisa ser abstraído: `System.Web`, `ConfigurationManager`, `HttpContext.Current`, `System.Drawing`. Cada bloqueio revela um ponto que precisa de Adapter.

**Degrau 5, introduzir DI, logging e configuração modernos** dentro do `net48`, via `Microsoft.Extensions.*`. Assim o código já está escrito no estilo do destino antes de mudar de plataforma.

**Degrau 6, criar a aplicação nova em .NET moderno ao lado**, referenciando as bibliotecas do degrau 4, e mover as rotas uma a uma com um proxy na frente. Este é o Strangler Fig propriamente dito.

**Degrau 7, desligar o antigo** quando não houver mais tráfego.

Muitos sistemas param confortavelmente no degrau 5, e isso é um resultado legítimo. Diga isso ao usuário, porque a alternativa mental costuma ser "ou migro tudo ou não faço nada".

## Strangler Fig na prática

O mecanismo é um roteador na frente das duas aplicações. Escolhas conforme o ambiente:

- **IIS com Application Request Routing** ou regras de reescrita, roteando por caminho.
- **YARP** hospedado no .NET moderno, com fallback para a aplicação antiga: as rotas migradas são tratadas localmente, o resto é encaminhado.
- **Load balancer** roteando por prefixo de caminho.

Ordem de migração das rotas, do menor risco para o maior:

1. Endpoints somente leitura, sem estado de sessão.
2. Endpoints novos, que nascem direto no sistema novo.
3. Escritas simples e idempotentes.
4. Fluxos transacionais complexos.
5. Autenticação e sessão, que costumam ser o último e o mais delicado.

Três problemas que você deve alertar antecipadamente, porque são os que mais atrasam esse tipo de projeto:

- **Sessão compartilhada.** As duas aplicações precisam reconhecer o mesmo login. Cookie de autenticação compartilhado exige chaves de proteção de dados compatíveis, e `FormsAuthentication` não é diretamente compatível com o .NET moderno. Planeje isso primeiro.
- **Banco compartilhado.** Duas aplicações escrevendo na mesma tabela precisam concordar sobre migrations e sobre concorrência. Defina quem é o dono do esquema.
- **Diferença de comportamento silenciosa.** Serialização de JSON, arredondamento de `decimal`, tratamento de nulo em query e cultura padrão mudam entre EF6 e EF Core, e entre Newtonsoft e `System.Text.Json`. Compare respostas lado a lado antes de trocar a rota.

## Bloqueadores conhecidos

O que simplesmente não vem junto para o .NET moderno, com a alternativa:

| Bloqueador | Alternativa |
|---|---|
| **Web Forms** | Sem caminho direto. Reescrever a camada de UI em MVC, Razor Pages ou Blazor. É o bloqueador mais caro |
| **WCF servidor** | CoreWCF, ou reescrever como Web API / gRPC |
| **WCF cliente** | Funciona via `System.ServiceModel.*` no .NET moderno, com limitações de binding (sem `wsHttpBinding` completo) |
| **Remoting, AppDomains** | Sem equivalente. Isolar por processo |
| **`System.Web` (HttpContext, Session, Cache)** | Reescrever atrás de abstrações. É o que o degrau 4 força a resolver |
| **`System.Drawing.Common`** | `ImageSharp`, `SkiaSharp` |
| **Enterprise Library, Unity antigo** | Container moderno |
| **`System.Configuration` com seções customizadas** | `Microsoft.Extensions.Configuration` |
| **Code Access Security, `[SecurityPermission]`** | Removido. Repensar o modelo de segurança |
| **MSMQ** | RabbitMQ, Azure Service Bus |
| **Crystal Reports, componentes COM** | Depende do fornecedor. Levantar antes de prometer prazo |
| **`BinaryFormatter`** | Removido por segurança. Trocar o formato de serialização, o que pode exigir migração de dados |
| **Dependência de 32 bits ou de COM registrado** | Manter em processo separado |
| **EF6 com `EDMX`** | Migrar para EF6 Code First primeiro, e depois para EF Core |

Recomendação prática de review: antes de estimar qualquer migração, rode o **.NET Upgrade Assistant** e o **API Portability Analyzer** para produzir a lista real de incompatibilidades. Estimativa sem esse levantamento é chute, e você deve dizer isso ao usuário em vez de arriscar um número.

## Anti-corruption layer

Durante a coexistência, o sistema novo não deve absorver o modelo do antigo, senão ele nasce legado. Coloque uma camada de tradução na fronteira: o novo define os contratos que quer, e adapters traduzem do antigo para eles.

Isso é o mesmo Adapter descrito em `patterns-no-legado.md`, aplicado na escala da integração entre os dois sistemas. Sem essa camada, o resultado típico é um sistema novo com o mesmo modelo de dados esquisito do antigo, e nesse caso a migração custou muito e resolveu pouco.

## Como apresentar isso num review

Se o usuário não pediu migração, no máximo uma nota curta: "existe um caminho incremental para modernizar isso sem reescrever, se houver interesse".

Se pediu, entregue:

1. **Onde está hoje:** framework, formato de projeto, tipo de aplicação, bloqueadores identificados.
2. **Degrau imediato de melhor retorno**, normalmente o 1 ou o 2, com esforço estimado.
3. **O primeiro bloqueador real**, que costuma ser Web Forms, WCF servidor, ou `HttpContext.Current` espalhado.
4. **Recomendação honesta de escopo.** Se a aplicação é estável, tem pouca mudança e nenhum requisito novo, parar nos degraus 1 e 2 pode ser a decisão economicamente correta. Diga isso, porque muitos projetos de migração começam sem que ninguém tenha perguntado se valia a pena.
