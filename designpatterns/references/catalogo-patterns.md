# Catálogo de Design Patterns orientado a decisão

Este catálogo não é enciclopédia. Cada verba responde: **que sintoma no código pede esse padrão, quando ele é a escolha errada, e o que o .NET já oferece pronto.**

## Índice

- [Mapa: o que varia leva ao padrão](#mapa-o-que-varia-leva-ao-padrão)
- [Gatilhos de detecção no código](#gatilhos-de-detecção-no-código)
- [Criacionais](#criacionais): Factory Method, Abstract Factory, Builder, Singleton, Prototype, Object Pool
- [Estruturais](#estruturais): Adapter, Decorator, Facade, Proxy, Composite, Bridge, Flyweight
- [Comportamentais](#comportamentais): Strategy, Observer, Command, Mediator, Chain of Responsibility, Template Method, State, Iterator, Visitor, Memento
- [Padrões de aplicação](#padrões-de-aplicação): DI, Options, Result, Repository, Unit of Work, Specification, CQRS
- [Padrões que se confundem](#padrões-que-se-confundem)
- [Padrões mal implementados](#padrões-mal-implementados)

---

## Mapa: o que varia leva ao padrão

Quase todo padrão faz a mesma coisa: separa o que muda do que não muda e coloca uma interface no meio. A diferença entre um e outro é **o que** está variando.

| O que varia | Padrão |
|---|---|
| O algoritmo (regra de cálculo, política, formato) | Strategy |
| A classe concreta que precisa nascer | Factory Method / Abstract Factory |
| Os passos de montagem de um objeto complexo | Builder |
| Comportamentos somados em combinações imprevisíveis | Decorator |
| A interface de algo que você não controla | Adapter |
| Quem reage quando algo acontece | Observer |
| Quem trata a requisição, e em que ordem | Chain of Responsibility |
| O comportamento conforme a situação atual do objeto | State |
| Um passo dentro de um fluxo fixo | Template Method |
| A origem dos dados | Repository |
| Um critério de negócio reutilizável | Specification |

## Gatilhos de detecção no código

Procure estes sinais mecânicos. Cada um aponta para um conjunto pequeno de padrões.

| Sinal no código | Investigue |
|---|---|
| `switch`/`if-else` sobre enum, string de tipo, ou `is` de tipo, com 3+ braços que crescem | Strategy (se escolhe *como fazer*), Factory (se escolhe *o que criar*), State (se os braços checam status do próprio objeto) |
| `new` de classe concreta dentro de regra de negócio | DI direto (preferir), Factory (se a escolha é dinâmica) |
| Construtor com 5+ parâmetros, maioria opcional | `required`/`init` (preferir), Builder (se há validação cruzada) |
| Método que faz cache, log, retry e a regra junto | Decorator |
| Tipo de biblioteca de terceiro aparecendo em regra de negócio | Adapter |
| `DateTime.Now`, `File.*`, `Environment.*` dentro de regra | Adapter (`TimeProvider`, `IFileSystem`) |
| Endpoint/controller com 6+ dependências injetadas | Facade, ou quebra por caso de uso |
| Um método dispara 4+ efeitos colaterais não relacionados | Observer / domain events, ou Outbox se precisar garantia |
| Três métodos com 90% de código igual e 10% diferente no meio | Template Method (passos fixos) ou Strategy (variação injetável) |
| `if (status == ...)` repetido em 3+ métodos da mesma classe | State ou tabela de transições |
| Cadeia de validações/autorizações onde cada etapa pode interromper | Chain of Responsibility |
| Repositório com 12+ métodos `GetByXAndY` | Specification |
| `.Instance` estático com estado mutável | Singleton mal feito, corrigir para `AddSingleton` |

---

## Criacionais

### Factory Method

- **Gatilho:** `new` de concreta escolhido por `if`/`switch` sobre string, enum ou tipo, dentro de uma classe que tem outra responsabilidade principal, e a lista de opções cresce.
- **Resolve:** tira de quem usa o objeto a decisão de qual objeto criar.
- **Quando NÃO:** existe uma implementação só; a fábrica só faria `return new X()`; é entidade de domínio (prefira `Order.Create(...)` estático).
- **Pronto no .NET:** `ILoggerFactory`, `IHttpClientFactory`, `IServiceProvider`, `ActivatorUtilities.CreateInstance<T>`, keyed services (`AddKeyedScoped` + `GetRequiredKeyedService`).
- **Forma idiomática:** injetar `IEnumerable<IHandler>` e indexar por chave, ou usar keyed services direto. Escrever fábrica na mão só quando a construção tem lógica além da escolha.
- **Armadilha de lifetime:** fábrica `Singleton` segurando serviços `Scoped` é captive dependency. Registre a fábrica como `Scoped`, ou injete `IServiceScopeFactory`.

### Abstract Factory

- **Gatilho:** família de objetos que só funcionam juntos (leitor + escritor + listador do mesmo storage; conexão + comando + transação do mesmo provider) e existe risco real de misturar peças.
- **Quando NÃO:** não há exigência de compatibilidade entre as peças (aí são fábricas independentes); a família ganha produtos novos com frequência, porque cada produto novo obriga mexer em todas as fábricas.
- **Custo:** alto em número de interfaces. Exija justificativa forte.

### Builder

- **Gatilho:** construtor telescópico; validação que só é possível com o conjunto completo; montagem com passos condicionais ou acumulação de coleções.
- **Quando NÃO:** o objeto tem 2 ou 3 campos; o builder só repassaria valores. Em C# moderno, `required` + `init` + argumentos nomeados resolvem a maior parte dos casos que exigiam Builder em Java.
- **Melhor uso prático:** Test Data Builder. Reduz drasticamente o custo de manter dezenas de testes quando o construtor da entidade muda.
- **Pronto no .NET:** `WebApplicationBuilder`, `StringBuilder`, `ConfigurationBuilder`, `DbContextOptionsBuilder`, `ResiliencePipelineBuilder`.

```csharp
// Preferir isto a um Builder quando é só preenchimento de campos
public sealed record ReportSpec
{
    public required string Title { get; init; }
    public required IReadOnlyList<string> Columns { get; init; }
    public ReportFormat Format { get; init; } = ReportFormat.Pdf;
}
```

### Singleton

- **Regra em .NET: não implemente o padrão clássico.** Você quer o *lifetime* singleton, e o container entrega isso com `AddSingleton<IFoo, Foo>()`.
- **Por que o clássico é ruim:** `.Instance` estático esconde a dependência (o construtor mente), impede substituição em teste, e cria estado global que faz testes paralelos interferirem entre si.
- **Três regras quando usar `AddSingleton`:**
  1. Thread safety interna obrigatória. Use `ConcurrentDictionary`, `Interlocked`, `Lock` (.NET 9+). Nunca `Dictionary`/`List` mutável cru.
  2. Nunca injete `Scoped` em `Singleton` (captive dependency). Use `IServiceScopeFactory` e crie escopo por operação.
  3. Não guarde estado de negócio nem de requisição. Cache, config, cliente HTTP e pool: sim. Usuário atual, carrinho: jamais.
- **Pronto no .NET:** `ILogger<T>`, `IMemoryCache`, `HybridCache`, `TimeProvider.System`, `ArrayPool<T>.Shared`, `IHostedService`.

### Prototype

- **Gatilho:** construção caríssima e necessidade de muitas variações a partir de uma base.
- **Em C# moderno:** a expressão `with` de `record` é Prototype nativo.
- **Armadilha:** `with` faz cópia rasa. Coleções são compartilhadas entre a cópia e a original. Use coleções imutáveis. Evite `ICloneable`, que não define se a cópia é rasa ou profunda.

### Object Pool

- **Gatilho:** alocação medida em caminho quente, com objeto caro de criar e seguro de reciclar.
- **Quando NÃO:** você não mediu. Objetos pequenos são baratos e a geração 0 do GC é rápida.
- **Pronto no .NET:** `ArrayPool<T>.Shared`, `ObjectPool<T>` (`Microsoft.Extensions.ObjectPool`).
- **Riscos a apontar em review:** `Return` fora de `finally`; uso após devolver (corrupção); buffer alugado não vem zerado, então serializar o array inteiro em vez de só a parte escrita pode vazar dados de outra requisição.

---

## Estruturais

Todos são "tenho um objeto dentro e delego". Muda a intenção.

| Padrão | Mantém a interface? | Intenção |
|---|---|---|
| Adapter | Não, expõe outra | Traduzir |
| Decorator | Sim | Acrescentar |
| Proxy | Sim | Controlar acesso |
| Facade | Cria nova e simples | Esconder subsistema |

### Adapter

- **Gatilho (o mais confiável de todos):** um tipo que você não escreveu aparece dentro da sua regra de negócio. `HttpResponseMessage`, `SqlDataReader`, DTO de SDK, `DateTime.Now`, `File`.
- **Resolve:** mantém o vocabulário externo fora do domínio. Trocar de fornecedor passa a ser escrever uma classe nova.
- **Quando NÃO:** a interface externa já é o que você quer; o adapter só renomearia métodos sem traduzir conceitos.
- **O adapter de maior retorno:** `TimeProvider` injetado, com `FakeTimeProvider` nos testes. Se o código tem `DateTime.Now` em regra de negócio, este é quase sempre um achado 🟠 legítimo.
- **Pronto no .NET:** `TimeProvider`, `ILogger` (adaptado para Serilog/NLog/console), `Stream`, `System.IO.Abstractions`.

### Decorator

- **Gatilho:** "quero acrescentar X sem mexer no que já funciona", onde X é preocupação transversal: cache, log, métrica, retry, autorização, auditoria, criptografia.
- **Gatilho combinatório:** 3 comportamentos opcionais exigiriam 8 subclasses por herança; com decorators, 3 classes cobrem as 8 combinações e a escolha é em runtime.
- **Quando NÃO:** a interface tem muitos métodos (cada decorator reimplementa todos, sinal de interface grande demais); o comportamento precisa de estado interno do objeto embrulhado; a pilha passaria de 3 ou 4 camadas.
- **Em review, verifique a ORDEM:** retry envolvendo cache tem comportamento diferente de cache envolvendo retry. Se a ordem não está documentada com comentário, aponte.
- **Composição:** manual em `AddScoped<T>(sp => ...)` deixa a ordem explícita; `Scrutor` com `.Decorate<,>()` deixa declarativo, e a última chamada é a camada mais externa.
- **Pronto no .NET:** `Stream` (`GZipStream` sobre `CryptoStream` sobre `FileStream`), `DelegatingHandler` no `HttpClient`, operadores LINQ.

### Facade

- **Gatilho:** endpoint ou controller orquestrando 5+ colaboradores, com a mesma sequência repetida em outro consumidor.
- **Regra de limite:** fachada **orquestra, não implementa regra de negócio**. Se ela começa a calcular imposto, a lógica pertence ao domínio.
- **Observação de review:** a maioria das classes `XService` em projetos .NET são fachadas sem o nome. Isso é aceitável. O problema é quando crescem para God Service.

### Proxy

- **Gatilho:** precisa controlar o acesso, não acrescentar comportamento. Sabores: virtual (lazy), protection (autorização), remote (rede), smart (contabilidade de recursos).
- **Pronto no .NET:** lazy loading proxies do EF Core, clientes gRPC/Refit, `Lazy<T>`, `WeakReference<T>`.
- **Achado clássico em review:** lazy loading do EF Core dentro de `foreach` gera N+1. Recomende `Include()` explícito ou projeção com `Select()`.

### Composite

- **Gatilho:** dados em árvore (menu, categoria, permissão, organograma) ou regras compostas por E/OU, onde o consumidor não deveria saber se lida com folha ou galho.
- **Quando NÃO:** hierarquia de dois níveis fixos (uma lista resolve); folhas e galhos têm operações genuinamente diferentes, e forçar a mesma interface produziria métodos que lançam exceção, violando Liskov.

### Bridge

- **Gatilho:** duas dimensões multiplicando em classes (`RelatorioPdfEmail`, `RelatorioPdfDisco`, `RelatorioExcelEmail`...). Bridge transforma NxM em N+M.
- **Nota prática:** o código sai quase igual a Strategy. Se houver dúvida, chame de Strategy, porque a equipe entende mais rápido.

### Flyweight

- **Gatilho:** milhões de instâncias e memória como gargalo **medido**.
- **Requisito absoluto:** o objeto compartilhado precisa ser imutável.
- **Pronto no .NET:** string interning, `Encoding.UTF8`, `CultureInfo.InvariantCulture`, `Task.CompletedTask`.

---

## Comportamentais

### Strategy

O padrão de melhor custo-benefício. Na dúvida entre Strategy e outro, verifique se o eixo é "como fazer".

- **Gatilho:** `switch` sobre modalidade/tipo/política escolhendo *como* executar, com braços independentes que crescem.
- **Sinal que torna Strategy obrigatório:** cada braço precisa de dependências diferentes (um chama API, outro lê banco, outro é cálculo puro). Sem Strategy, o construtor do contexto precisa de todas ao mesmo tempo.
- **Ganho que o `switch` nunca dá:** as estratégias se tornam coleção manipulável. "Cotar todas as modalidades ordenadas por preço" passa a ser uma linha.
- **Quando NÃO:** dois casos triviais e estáveis (um `if` é mais legível que duas classes); as estratégias compartilham 80% do código (é Template Method); elas precisam rodar em sequência ou se conhecer (é Chain of Responsibility).
- **Versão leve:** se a estratégia é função pura de uma linha sem dependências, um `Dictionary<TKey, Func<...>>` resolve sem interface nem classe.
- **Pronto no .NET:** `IComparer<T>`, `IPasswordHasher<TUser>`, `IAuthorizationHandler`, `JsonNamingPolicy`, providers de `IDistributedCache`.

### Observer

- **Gatilho:** um fato do domínio dispara N reações independentes, e você quer acrescentar reação sem tocar em quem publica.
- **Três problemas de `event` em aplicação web:** referência forte causa vazamento se não houver `-=`; é síncrono e `void`, e `async void` engole exceção e derruba o processo; um handler que lança interrompe os demais.
- **Forma recomendada server-side:** handlers resolvidos por DI (`IEnumerable<IDomainEventHandler<T>>`), despachados com `try/catch` por handler para isolar falhas.
- **Decisão crítica de review:** se a reação **não pode** falhar silenciosamente, Observer em memória é a ferramenta errada. Recomende **Outbox**: gravar o evento na mesma transação e publicar em fila com retry. Observer avisa, fila garante.
- **Quando NÃO:** há ordem obrigatória entre as reações (o fluxo fica implícito e indepurável, prefira código sequencial); você precisa do resultado dos ouvintes; eventos disparando eventos em cascata.
- **Pronto no .NET:** `event`/`EventHandler<T>`, `IObservable<T>`/Rx, `INotifyPropertyChanged`, `IChangeToken`, `CancellationToken.Register`.

### Command

- **Gatilho:** precisa de undo/redo, fila, agendamento, auditoria de ações, ou pipeline uniforme de validação e transação.
- **Por que compensa:** ação que é objeto pode ser serializada, registrada, reexecutada, invertida e passada por pipeline.
- **Quando NÃO:** CRUD simples. Comando + handler + pipeline para salvar um cadastro é cerimônia sem retorno.
- **Undo:** Command guarda a operação inversa (econômico, exige saber inverter). Memento guarda o estado inteiro (simples, pesado).

### Mediator

- **Aviso de review:** é o padrão mais sobreutilizado do ecossistema .NET. Troca uma chamada rastreável (F12 leva ao código) por indireção onde "ir para a definição" não leva a lugar nenhum.
- **O único ganho real:** o **pipeline de behaviors** (validação, log, transação, cache aplicados a todas as operações num só lugar). Sem pipeline, injete o handler direto.
- **Nota de licenciamento (verificar antes de recomendar):** MediatR e MassTransit passaram a exigir licença comercial em versões recentes. Alternativas: Wolverine, mediator próprio de ~40 linhas, ou handler injetado direto.
- **Quando NÃO:** poucos endpoints sem preocupação transversal; handlers chamando outros handlers (acoplamento disfarçado e pior de depurar).

### Chain of Responsibility

- **Gatilho:** vários tratadores possíveis, você não sabe de antemão qual resolve, e cada etapa pode **interromper** o fluxo.
- **Diferença de Decorator:** na Chain, um elo pode não chamar o próximo. Decorator sempre delega.
- **Quando NÃO:** você sabe quem trata (chame direto); todos os tratadores sempre executam sem interromper (é `foreach` numa lista).
- **Pronto no .NET:** middleware do ASP.NET Core, `DelegatingHandler`, endpoint filters (`AddEndpointFilter`), `ResiliencePipeline` do Polly v8, `IExceptionHandler` (.NET 8+).

### Template Method

- **Gatilho:** vários fluxos com a mesma sequência e 1 a 3 passos diferentes, e você quer garantir a ordem (log sempre antes, commit sempre depois).
- **Quando NÃO:** hierarquia passando de dois níveis; subclasses sobrescrevendo quase tudo (o template não capturou nada em comum); passos precisando de dependências injetadas próprias (use Strategy).
- **Regra de escolha:** em código novo, prefira Strategy. Composição envelhece melhor que herança.
- **Pronto no .NET:** `BackgroundService` (você implementa `ExecuteAsync`), `DbContext.OnModelCreating`, `Stream.CopyTo`.

### State

- **Gatilho:** `if (status == ...)` em 3+ métodos da mesma entidade, e transições inválidas causam bug de negócio real.
- **Por que dói sem o padrão:** a máquina de estados não existe em lugar algum, está espalhada, e ninguém responde "de Paid, para onde posso ir?" sem ler o arquivo todo.
- **Forma completa:** classe base cujo comportamento padrão é proibir, e cada estado habilita só o que permite, devolvendo o próximo estado.
- **Forma leve (frequentemente melhor):** `FrozenDictionary<(Status, Action), Status>` como tabela de transições. Entrega 80% do ganho com 20% do código e funciona como documentação executável.
- **Quando NÃO:** dois estados (um `bool` resolve); status é rótulo de exibição sem regra. Máquina muito grande e crítica: considere biblioteca dedicada (Stateless).

### Iterator

- **Em C#, é `yield return`.** O valor é avaliação preguiçosa com memória constante.
- **Achados de review sobre preguiça:** `try/catch` em volta da chamada não captura nada, porque a exceção acontece na iteração; iterar duas vezes executa duas vezes (duas queries); iterar após descartar o `DbContext` gera `ObjectDisposedException`.
- **Regra:** método público que devolve algo já em memória deve materializar (`ToArray()`) e devolver `IReadOnlyList<T>`. Reserve `IEnumerable<T>` preguiçoso para streaming real. Para streaming assíncrono, `IAsyncEnumerable<T>` com `[EnumeratorCancellation]`.

### Visitor

- **Gatilho:** hierarquia de tipos **estável** com operações que crescem muito.
- **Em C# moderno, pattern matching quase sempre vence.** A cerimônia `Accept`/`Visit` existia porque linguagens antigas não tinham despacho por tipo. Um `switch` de padrões faz o mesmo com muito menos código.
- **Custo assimétrico:** adicionar tipo novo obriga mexer em todos os visitors. Se a hierarquia cresce, Visitor é a pior escolha.
- **Pronto no .NET:** `ExpressionVisitor`, usado pelos provedores LINQ (o EF Core traduz árvore de expressão em SQL assim).

### Memento

- **Gatilho:** salvar e restaurar estado interno sem violar encapsulamento (snapshot opaco).
- **Pronto no .NET:** `ChangeTracker` do EF Core guarda valores originais; savepoints de transação.

---

## Padrões de aplicação

### Injeção de dependência

Distinção que vale explicitar em review: **DIP** é o princípio (dependa de abstração), **IoC** é o conceito (o framework controla o fluxo), **DI** é a técnica (receber pelo construtor).

Tempos de vida e a regra de ouro:

| Lifetime | Uma instância por | Use para |
|---|---|---|
| `AddSingleton` | processo | cache, config, cliente HTTP, `TimeProvider` |
| `AddScoped` | requisição | `DbContext`, repositórios, casos de uso |
| `AddTransient` | injeção | objetos leves sem estado, validadores |

**Nunca dependa de algo com vida mais curta que a sua.** Singleton para Scoped é captive dependency, e um `DbContext` preso em singleton acumula entidades rastreadas e vaza dados entre requisições. A validação de escopo do container detecta isso na inicialização em Development, então nunca desligue.

**Anti-padrão a marcar como 🟠 ou 🔴:** Service Locator. `IServiceProvider` injetado com `GetService<T>()` no meio da regra esconde as dependências, faz o construtor mentir, e transfere a falha para runtime. Aceitável apenas em fábricas legítimas e na composição da raiz.

### Options

- **Gatilho:** `IConfiguration["Secao:Chave"]` espalhado, com string mágica e sem validação.
- **Forma correta:** classe tipada com `required`/`init`, `AddOptions<T>().BindConfiguration(...).ValidateDataAnnotations().ValidateOnStart()`. Config errada derruba a aplicação na subida em vez de falhar em produção.
- **Qual interface:** `IOptions<T>` não recarrega (singletons, config estática); `IOptionsSnapshot<T>` recarrega por escopo; `IOptionsMonitor<T>` recarrega na hora com callback (singletons que reagem a mudança).

### Result

- **Regra de decisão:** se está no fluxo normal do negócio, é retorno. Se é defeito ou algo fora do seu controle, é exceção. "Saldo insuficiente" é resultado; falha de rede é exceção.
- **Ganhos:** a assinatura documenta que pode falhar; muito mais rápido que exceção; múltiplos erros de validação em um retorno.
- **Custos:** verbosidade, propagação manual, e meio caminho (metade Result, metade exceção) é o pior dos mundos.
- **Combine com** `IExceptionHandler` (.NET 8+) como rede de segurança e traduza para `ProblemDetails` (RFC 9457) na borda HTTP.

### Repository e Unit of Work

**Ponto mais importante:** o `DbContext` do EF Core **já é** Repository (`DbSet<T>`) e **já é** Unit of Work (`SaveChangesAsync`). Envolver isso em `IRepository<T>` + `IUnitOfWork` costuma ser trabalho sem retorno.

Vale usar Repository quando: há DDD com carga/salvamento por agregado; existem queries de negócio que merecem nome (`GetPendingShipmentAsync`); você precisa realmente trocar de fonte.

Não vale quando: é CRUD e o objetivo é "abstrair o EF"; os métodos são `GetAll`/`GetById`/`Add`; os testes usam Testcontainers ou `WebApplicationFactory` e não precisam de mock.

Anti-padrão a marcar em review:

```csharp
public interface IRepository<T> where T : class
{
    Task<IEnumerable<T>> GetAllAsync();  // traz a tabela inteira, sempre
    IQueryable<T> Query();               // "abstração" que vaza o EF para todas as camadas
    Task SaveAsync();                    // commit por entidade, destrói a transação
}
```

Meio-termo que funciona: **Repository para escrita** (consistência do agregado) e **query direta com projeção para leitura**. Isso é CQRS na prática.

### Specification

- **Gatilho:** repositório com muitos métodos `GetByXAndY`, ou a mesma condição de negócio duplicada em SQL e em memória.
- **Ganho real:** dar **nome de negócio** à regra e usá-la nos dois mundos, no banco via `Expression<Func<T,bool>>` e em memória via `IsSatisfiedBy`, sem risco de divergirem.
- **Quando NÃO:** filtro simples usado uma vez. `Where(c => !c.IsBlocked)` é mais legível que três classes.

### CQRS

- **Forma útil e barata:** duas pastas, dois modelos, um banco. Escrita com entidade rica e transação; leitura com projeção e `AsNoTracking`.
- **Desfaça a confusão:** CQRS não é event sourcing e não exige bancos separados. Bancos separados com sincronização por eventos e consistência eventual são nível avançado, justificável só com assimetria enorme de carga.

---

## Padrões que se confundem

O código sai quase idêntico. A pergunta à direita resolve.

| Par | Pergunta que separa |
|---|---|
| Strategy vs State | **Quem escolhe?** Strategy: quem chama, de fora. State: o próprio objeto, e os estados conhecem seus sucessores |
| Decorator vs Proxy | **Para quê?** Decorator acrescenta. Proxy controla acesso |
| Adapter vs Facade | **Quantos objetos?** Adapter converte um objeto para interface que já existe. Facade cria interface nova sobre vários |
| Factory vs Builder | **O que é difícil?** Factory decide qual tipo (um passo). Builder decide como montar (vários passos) |
| Mediator vs Observer | **Quem sabe de quem?** Mediator conhece todos. No Observer o emissor não conhece ninguém |
| Template Method vs Strategy | **Herança ou composição?** Subclasse em compilação vs objeto injetado em runtime |
| Chain vs Decorator | **Pode parar?** Chain pode não chamar o próximo. Decorator sempre delega |
| Composite vs Decorator | **Quantos filhos?** Decorator embrulha exatamente um. Composite contém vários |

---

## Padrões mal implementados

Encontrar isto em review é mais valioso que encontrar ausência de padrão, porque dá falsa sensação de qualidade. Severidade sugerida entre parênteses.

| Sintoma | O que está errado | Correção |
|---|---|---|
| `public static Foo Instance` com estado mutável (🔴) | Singleton clássico: dependência escondida, intestável, estado global | `AddSingleton<IFoo, Foo>` com interface e construtor público |
| Singleton com `Dictionary`/`List` mutável (🔴) | Não é thread safe, e será acessado concorrentemente | `ConcurrentDictionary`, `FrozenDictionary` se imutável, ou lock explícito |
| Repository devolvendo `IQueryable<T>` (🟠) | Não abstrai nada, vaza EF para todas as camadas, e o consumidor pode compor query que quebra em runtime | Métodos com intenção de negócio devolvendo `IReadOnlyList<T>` materializado |
| Strategy cujo contexto tem `if` para escolher a estratégia (🟠) | O `switch` só mudou de lugar; o contexto voltou a conhecer as concretas | Dicionário por chave, `IEnumerable<T>` injetado, ou keyed services |
| Decorator que altera o contrato (🔴) | Quebra Liskov: quem consome a interface recebe comportamento diferente do prometido | Decorator só complementa. Se precisa mudar o contrato, é outra abstração |
| `IServiceProvider` injetado em regra de negócio (🟠) | Service Locator disfarçado de DI | Dependências explícitas no construtor |
| Interface com uma implementação e nenhum teste que a use (🟡) | Abstração de um: indireção sem retorno | Remover a interface, ou justificar com a seam de teste |
| `event` sem `-=` em objeto de vida longa (🔴) | Vazamento de memória por referência forte | `IDisposable` removendo a inscrição, ou weak event |
| Factory que só faz `return new X()` (🟡) | Nenhuma decisão sendo encapsulada | Injetar a concreta ou a interface direto |
| Interface criada mas consumidor faz `new` da concreta (🟠) | Padrão pela metade: falsa sensação de desacoplamento | Registrar no container e injetar |
| `async void` fora de event handler (🔴) | Exceção não capturável, derruba o processo | `async Task` |
| `.Result`/`.Wait()` em código async (🔴) | Risco de deadlock e de bloqueio de thread pool | `await` até a borda |
| Observer com handler que lança e interrompe os demais (🟠) | Falha de uma reação opcional cancela reações não relacionadas | `try/catch` por handler, ou Outbox se a entrega precisa ser garantida |
| `Rent` sem `Return` no `finally` (🟠) | Perde o ganho do pool, ou corrompe dados se devolvido cedo | `try/finally` |
| Generic Repository com `GetAll()` alimentando filtro em memória (🔴) | Traz a tabela e filtra na aplicação. Não escala | Query com `Where` no banco e projeção |
