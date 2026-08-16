# Auditoria técnica: async, concorrência e performance

**Data:** 2026-08-14
**Auditor:** perspectiva de especialista em performance .NET
**Arquivos auditados (não modificados):**

- `C:\Users\welli\OneDrive\Desktop\Estudos\Skills\dotnet-code-review\designpatterns\references\dotnet-moderno.md`
  — seções: Async e concorrência, CancellationToken, Injeção de dependência e lifetimes, HttpClient e resiliência, Performance e alocação, Descarte de recursos
- `C:\Users\welli\OneDrive\Desktop\Estudos\Skills\dotnet-code-review\designpatterns-legacy\references\smells-legado.md`
  — seções: O deadlock de sync-over-async, Async no legado

**Veredito geral.** A qualidade é alta para um checklist de review: as gravidades são bem calibradas, o preâmbulo de "Performance e alocação" ("otimização sem medição é aposta") é exatamente a postura correta, e a maioria das linhas descreve defeitos reais. O que compromete a credibilidade são **quatro mecanismos explicados errado** (o mais grave está justamente na seção que o próprio documento diz que "merece explicação completa"), **três recomendações que introduzem bug novo** e a **ausência quase total das armadilhas de alocação e de GC** que aparecem em review real.

Contagem: 13 erros factuais, 9 conselhos perigosos, 13 blocos de lacuna, 11 achados de legado.

---

## (a) ERROS FACTUAIS

### A1 🔴 O mecanismo do deadlock de sync-over-async está errado

**Local:** `smells-legado.md`, "O deadlock de sync-over-async", parágrafo após o exemplo de código.

> "a `Task`, ao terminar seu `await` interno, tenta retomar **na mesma thread do contexto**, que está bloqueada esperando por ela."

Errado. O `AspNetSynchronizationContext` (ASP.NET clássico em modo 4.5+) **não tem afinidade de thread**. A primeira frase da seção está correta ("permite apenas uma thread por vez"), e é exatamente ela que contradiz a segunda: o contexto é um **lock de exclusão mútua associado à requisição**, não uma thread específica.

Mecanismo correto:

1. A thread da requisição entra no contexto (adquire o lock exclusivo) e bloqueia em `.Result`.
2. Ao completar o `await` interno, a continuação é **postada** no `AspNetSynchronizationContext`.
3. O contexto só admite uma thread por vez e o lock está tomado pela thread bloqueada. A continuação fica na fila e **nenhuma thread do pool pode executá-la** — não porque precise ser aquela thread, mas porque a entrada no contexto está fechada.
4. Deadlock.

A distinção não é acadêmica, ela muda a conclusão de um review:

- Em **WinForms/WPF** a explicação do documento está certa — ali existe afinidade de thread real (message pump).
- Em **ASP.NET clássico** é lock, não afinidade. É por isso que `Task.Run(() => X()).GetAwaiter().GetResult()` **funciona** como escape (a cadeia async passa a rodar sem contexto capturado) — resultado que fica inexplicável para quem acredita na versão "mesma thread".
- Quem lê "mesma thread" tende a concluir que jogar parte da cadeia em outra thread já resolve, o que é falso se a captura do contexto continuar acontecendo nos `await` internos.

Redação sugerida: *"a continuação é postada no contexto da requisição, que admite apenas uma thread por vez; o lock está tomado pela thread bloqueada, então nenhuma thread do pool consegue entrar para executar a continuação. Ao contrário do contexto de UI, não é a mesma thread que é exigida — é a entrada exclusiva no contexto que está fechada."*

### A2 🔴 "Chamada externa sem timeout trava o pool de threads" — mecanismo errado e premissa falsa

**Local:** `dotnet-moderno.md`, "HttpClient e resiliência".

> `Chamada externa sem timeout` | 🔴 | `Uma dependência lenta trava o pool de threads`

Dois problemas.

**Mecanismo errado.** Uma chamada HTTP `await`ada não consome thread do pool enquanto espera — é justamente o ponto do I/O assíncrono. Sem código bloqueante na cadeia, uma dependência lenta **não** trava o pool. O documento acerta o mecanismo em outra linha (`.Result` → starvation) e aqui atribui o mesmo efeito à causa errada. Um autor de PR que conheça async vai descartar a observação — e com razão.

Consequências reais de chamada externa sem limite de tempo:
- requisições acumulam estado em memória (buffers, `HttpRequestMessage`, escopo de DI com `DbContext` vivo por requisição pendente) → crescimento de RSS proporcional à concorrência pendente;
- esgotamento de limites de concorrência de saída (`MaxConnectionsPerServer`, pool de conexões ADO.NET, permits do rate limiter);
- latência em cascata: o cliente a montante estoura o timeout dele e reenvia, multiplicando carga;
- fila de requisições do Kestrel crescendo → 503 / falha de health check;
- starvation do pool **apenas** se houver bloqueio na cadeia.

**Premissa falsa.** `HttpClient` **tem** timeout padrão de **100 segundos** — "sem timeout" quase nunca significa infinito, significa "com um timeout absurdamente longo para o SLA". E se o cliente usa `AddStandardResilienceHandler`, os defaults documentados são 30 s total, 10 s por tentativa, 3 retries. A linha deve dizer: *"timeout não configurado (fica nos 100 s do default, ou 30 s do handler padrão) — defina de acordo com o SLA da dependência"*.

### A3 🔴 "Exceção mata o serviço silenciosamente e ele não reinicia" é comportamento pré-.NET 6

**Local:** `dotnet-moderno.md`, "Background services", linha `ExecuteAsync` sem `try/catch` no loop.

O documento declara no topo que assume ".NET 8 ou superior", e esta linha descreve o comportamento de .NET Core 3.1/5.

Comportamento atual (confirmado na doc de breaking change de .NET 6 e em `HostOptions.BackgroundServiceExceptionBehavior`): o default é **`StopHost`**. Uma exceção não tratada em `ExecuteAsync` é **logada** e **para o host inteiro**. O default antigo era `Ignore`, que produzia os "zombie processes" — é esse que "mata o serviço silenciosamente".

A gravidade 🔴 continua correta, mas o problema a apontar é **mais grave e diferente**: uma falha transitória num hosted service derruba **toda a aplicação**, inclusive a API que atende tráfego no mesmo processo. Detalhe operacional que fecha o raciocínio: o host para **de forma limpa**, com exit code 0 (até .NET 10; em .NET 11 passa a propagar exceção e exit code não-zero), então o Windows Service manager e o Kubernetes podem **não reiniciar** — que é a única parte da frase original que se sustenta, por outro motivo. Se o restart é desejado, é preciso `Environment.Exit(nonZero)` no catch.

Redação sugerida: *"Exceção não tratada em `ExecuteAsync` para o host inteiro (default `StopHost` desde .NET 6), derrubando também a API no mesmo processo — e para com exit code 0, então o orquestrador pode não reiniciar."*

### A4 🟠 `HostingEnvironment.QueueBackgroundWorkItem` é 4.5.2, não 4.5

**Local:** `smells-legado.md`, "Async no legado".

> `Use `HostingEnvironment.QueueBackgroundWorkItem` (net45+)`

A API foi introduzida em **.NET Framework 4.5.2** ("What's new in .NET Framework 4.5.2", `System.Web.Hosting.HostingEnvironment`). Num projeto `net45` ou `net451` a sugestão não compila. Corrigir para `(net452+)`. Ver também D2 para as ressalvas de uso que faltam.

### A5 🟠 `Count()` em `IEnumerable` não enumera coleções — a linha diagnostica a coisa errada

**Local:** `dotnet-moderno.md`, "Performance e alocação".

> `Count()` em `IEnumerable` quando existe `Count` | `Sempre: evita enumerar`

`Enumerable.Count()` tem fast path: testa `ICollection<T>` / `ICollection` e devolve `.Count` **sem enumerar**. Um `List<T>`, `T[]` ou `Dictionary` tipado como `IEnumerable<T>` não é enumerado por `Count()`. O "Sempre: evita enumerar" está factualmente errado para o caso mais comum.

O defeito real, que a linha perde:
- `Count()` sobre cadeia LINQ lazy (`.Where(...).Count()` em memória) → enumera de verdade;
- `Count()` sobre `IQueryable` → **round trip extra ao banco**, e dentro de loop é N+1 de contagem (esse sim é 🔴 e não está em nenhum dos dois documentos);
- `Count()` sobre `IAsyncEnumerable`/gerador → materializa tudo.

Correção: *"`Count()` sobre sequência lazy ou `IQueryable` (round trip extra; dentro de loop, N+1). Use `Count`/`Length` quando existir estaticamente, ou `TryGetNonEnumeratedCount` (.NET 6+) quando o tipo é desconhecido."*

### A6 🟠 `Any()` "sempre" melhor que `Count() > 0` é falso — e contradiz a linha anterior

**Local:** `dotnet-moderno.md`, "Performance e alocação", linha imediatamente seguinte a A5.

> `Any()` versus `Count() > 0` | `Sempre: Any() para-cedo`

Sobre coleção materializada, `list.Count > 0` é O(1) e sem alocação, enquanto `Any()` **aloca um enumerador** (e faz boxing do enumerador struct de `List<T>`, mais dispatch por interface). Nesse caso `Count > 0` é estritamente mais rápido — o oposto do que a linha afirma com "Sempre".

Além disso as duas linhas se contradizem: A5 diz "use a propriedade `Count`", A6 diz "nunca use `Count`". Um revisor que siga a tabela literalmente vai pedir mudanças em direções opostas no mesmo arquivo.

Regra correta:
- coleção materializada (`List`, array, `ICollection`) → `.Count > 0` / `.Length > 0`;
- sequência lazy ou `IQueryable` → `Any()` (para-cedo em memória, `EXISTS` em vez de `COUNT(*)` no banco). Aqui o ganho é real e grande;
- `Any(predicate)` vs `Where(predicate).Any()` → o primeiro.

### A7 🟠 "aceitam token em todos os métodos assíncronos" é falso, e aceitar ≠ honrar

**Local:** `dotnet-moderno.md`, "CancellationToken".

> "`EF Core`, `HttpClient`, `Stream` e `Channel` aceitam token em todos os métodos assíncronos."

Falso como universal (`Stream.ReadAsync(byte[],int,int)` e `CopyToAsync(Stream)` têm sobrecargas sem token; várias APIs de `HttpClient` só ganharam sobrecarga com token em .NET 5), mas o problema sério é outro: **aceitar o token não significa honrá-lo**, e o próprio documento diz duas linhas acima que "token aceito e ignorado é pior que não aceitar".

Casos em que o token é aceito e efetivamente ignorado ou parcial:
- `FileStream` aberto **sem** `useAsync: true`/`FileOptions.Asynchronous` → I/O síncrono embrulhado, token não interrompe;
- `DeflateStream`, `GZipStream`, `CryptoStream` sobre stream síncrono;
- cancelamento de comando em voo no banco é **best-effort**: o `SqlCommand` pode já ter sido executado no servidor; a transação pode precisar de rollback explícito;
- `IAsyncEnumerable` gerado por iterador sem `[EnumeratorCancellation]` — o token de `WithCancellation(ct)` é silenciosamente descartado (ver C4).

A afirmação como está dá ao revisor uma falsa garantia de completude.

### A8 🟠 `Monitor` entre `await`s: o defeito é afinidade de thread, não "corromper estado"

**Local:** ambos os documentos, linha `lock` em volta de `await` / `await` dentro de `lock`.

> "Não compila com `lock`, e usar `Monitor` manualmente entre awaits corrompe o estado"

A primeira metade está certa (CS1996). A segunda descreve o sintoma errado. `Monitor` é **thread-afim**: o lock pertence à thread que o adquiriu. Depois de um `await`, a continuação normalmente roda em **outra** thread do pool, e então:

- `Monitor.Exit` naquela thread lança `SynchronizationLockException`, ou
- a thread original nunca libera → o lock fica **permanentemente tomado** e todo mundo que tentar entrar bloqueia para sempre, ou
- o `lock` é reentrante por thread, então o "mesmo" fluxo lógico consegue reentrar por acidente e a exclusão mútua simplesmente **não existe** — aí sim há corrupção, mas como consequência, não como mecanismo.

Vale acrescentar que `System.Threading.Lock` (.NET 9+), recomendado noutra linha do mesmo documento, tem a mesma restrição: `Lock.EnterScope()` devolve um `ref struct`, portanto não é possível `await` dentro do escopo — falha de compilação, o que é o comportamento desejado.

### A9 🟠 `async void`: "não é capturável" e "derruba o processo" precisam de qualificação

**Local:** `dotnet-moderno.md` "Async e concorrência" e `smells-legado.md` "Async no legado".

> "Exceção não é capturável e derruba o processo" / "Exceção em `async void` não é capturável e derruba o worker process"

Duas imprecisões:

1. **É capturável dentro do próprio método** `async void`. O que é impossível é capturar **no chamador** — nem `try/catch` em volta da chamada, nem `await`, nem `ContinueWith`. Essa é a formulação que ajuda o revisor a explicar o defeito.
2. O destino da exceção é o `SynchronizationContext` **capturado na entrada** do método (`AsyncVoidMethodBuilder.SetException`):
   - **sem contexto** (ASP.NET Core, timer, thread de background): relançada no thread pool → derruba o processo. Aqui a afirmação está correta.
   - **em ASP.NET clássico** com contexto task-friendly: relançada no contexto da requisição, o que tipicamente **falha aquela requisição** (500), não o worker process. O sintoma canônico de `async void` numa página/módulo legado é `"An asynchronous module or handler completed while an asynchronous operation was still pending."`
   - **em UI**: vai para o dispatcher/`Application.DispatcherUnhandledException`.

Ambos permanecem 🔴. Nomear o sintoma certo por plataforma é o que faz o achado ser aceito em vez de contestado.

### A10 🟠 Validação de escopo: não é "a única" detecção, e por padrão só roda em Development

**Local:** `dotnet-moderno.md`, "Injeção de dependência e lifetimes".

> `Validação de escopo desligada` | 🟠 | `Remove a única detecção automática de captive dependency`

Dois erros:

1. Não é a única: `ValidateOnBuild` também existe e pega dependências não registradas e parte dos problemas de grafo na subida.
2. Mais importante: no host padrão, `ValidateScopes` é ligado **apenas quando o ambiente é Development**. Ou seja, na configuração default a detecção **já está desligada em produção** — não é preciso alguém desligar. A linha deveria ser: *"não habilitada fora de Development (default do host). Ligue `ValidateScopes` e `ValidateOnBuild` em todos os ambientes, ou trate captive dependency como achado manual — a validação não pega captura via `IServiceProvider` guardado em campo nem via delegate de factory."*

### A11 🟡 "risco de deadlock" em `.Result` no documento moderno, sem qualificar

**Local:** `dotnet-moderno.md`, "Async e concorrência".

> `.Result`, `.Wait()`, `.GetAwaiter().GetResult()` | 🔴 | `Bloqueia thread do pool; risco de deadlock e de thread pool starvation sob carga`

O mesmo documento afirma três linhas abaixo que em ASP.NET Core "não há `SynchronizationContext`". Em ASP.NET Core não existe o deadlock clássico por contexto. Manter "risco de deadlock" sem qualificar torna a tabela internamente inconsistente e ensina o mecanismo errado.

Em .NET 8+ o deadlock aparece por outros caminhos, que valem a pena estar nomeados:
- **starvation-induzido**: a thread bloqueada consome um worker; o pool injeta ~1–2 threads/s depois do mínimo; sob rajada o sistema para de progredir — deadlock na prática;
- **construtor estático**: o CLR mantém o lock do `cctor`; bloquear numa `Task` cuja continuação toque o mesmo tipo trava para sempre, **em qualquer host, inclusive console** (documentado pela Microsoft em "Common async/await bugs");
- **contexto de concorrência limitada ainda existente**: xUnit v2 instala `AsyncTestSyncContext`, então `.Result` **deadlocka em teste** mesmo em projeto .NET 8 (xUnit v3 removeu); `TaskScheduler` customizado (TPL Dataflow, `Parallel` com scheduler próprio) tem o mesmo efeito;
- **bibliotecas consumidas por MAUI/WPF/legado**.

### A12 🟡 `ConfigureAwait(false)`: a ressalva é mais ampla que "UI/legado"

**Local:** `dotnet-moderno.md`, "Async e concorrência".

> `Pode remover; obrigatório apenas em bibliotecas que também rodam em UI/legado`

A conclusão principal (🟢, não é defeito em ASP.NET Core) está **correta** e é uma das linhas mais úteis da tabela. Faltam três ressalvas:

- `ConfigureAwait` age sobre `SynchronizationContext` **e** `TaskScheduler.Current`. Código que pode rodar sob um scheduler não-default (TPL Dataflow, `Parallel` com scheduler custom) se beneficia mesmo sem contexto;
- host de teste pode instalar `SynchronizationContext` (xUnit v2), então "não há contexto" não vale para o assembly de teste;
- em .NET 8+ existe `ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing | ForceYielding | ContinueOnCapturedContext)`; `ConfigureAwait(false)` é açúcar para `ConfigureAwaitOptions.None`. Um review moderno que discute a chamada deve conhecer as opções.

Ressalva prática: "pode remover" em código de aplicação é seguro, mas em biblioteca do mesmo repo é **mudança de comportamento** para consumidores que você não enumerou. Como é 🟢, o melhor conselho é "não peça a remoção, só não peça a adição".

### A13 🟡 `new HttpClient()` por requisição: TIME_WAIT é só um dos dois modos de falha

**Local:** `dotnet-moderno.md`, "HttpClient e resiliência".

> `new HttpClient()` por requisição | 🔴 | `Socket exhaustion (portas em TIME_WAIT)`

Correto, mas TIME_WAIte só acontece quando o handler **é** descartado. Os dois modos de falha são distintos e ambos aparecem em review:

- **com `using`/`Dispose`**: cada conexão fechada fica em `TIME_WAIT` (~240 s no Windows por default) → esgotamento de portas efêmeras;
- **sem `Dispose`**: vaza `HttpMessageHandler` e o pool de conexões dele; conexões e sockets ficam vivos até o GC coletar e finalizar → RSS e handles crescendo, sintoma que se confunde com memory leak.

Vale registrar que em .NET Core o dano é menor por conexão que no Framework, mas ainda é 🔴. Ver C12 para o remédio ausente do caso singleton.

---

## (b) CONSELHO PERIGOSO

### B1 🔴 "Remover `async` e devolver a `Task`" muda semântica e cria bugs

**Local:** `dotnet-moderno.md`, "Async e concorrência".

> `async` sem `await` no corpo | 🟡 | `Máquina de estado sem necessidade` | `Remover `async` e devolver a `Task``

Esse é o conselho mais perigoso do documento moderno, porque parece inofensivo (🟡, "só tira overhead") e é aplicado mecanicamente. Elidir `async`/`await` **muda o comportamento observável** em quatro formas:

**1. Exceção síncrona em vez de `Task` faulted.** Com `async`, tudo que é lançado antes do primeiro `await` — inclusive validação de argumento — vira uma `Task` no estado faulted. Sem `async`, é lançado **na chamada**. Quebra:

```csharp
// antes (async): lança dentro da task
var tasks = items.Select(GetAsync).ToList();   // nada lança aqui
await Task.WhenAll(tasks);                     // ArgumentException observada aqui

// depois (elidido): lança no Select, WhenAll nunca é alcançado
// e o try/catch em volta do await não pega mais nada
```

**2. `using`/`await using` é descartado antes da Task completar.** Este é o bug clássico, e silencioso:

```csharp
// ERRADO: elidido — o scope é descartado ao retornar, antes da query terminar
public Task<List<Order>> GetAsync()
{
    using var scope = _factory.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    return db.Orders.ToListAsync();     // ObjectDisposedException, ou pior: intermitente
}

// CERTO: async/await mantém o scope vivo até a conclusão
public async Task<List<Order>> GetAsync()
{
    using var scope = _factory.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    return await db.Orders.ToListAsync();
}
```

O mesmo vale para `try/catch`, `try/finally`, `lock`, `foreach` sobre enumerador descartável e qualquer `SemaphoreSlim.Release()` em `finally` — todos rodam **antes** da Task completar.

**3. Stack trace perde o frame** do método elidido, dificultando diagnóstico em produção.

**4. `Task` de outra origem é repassada por referência** — o chamador pode `await`á-la duas vezes, ou o retorno pode ser um `Task` já cacheado por terceiros com semântica diferente.

**Regra correta a colocar no documento:** *só elide quando o corpo é um único `return metodoAsync(...)` puro, sem `using`, sem `try`, sem `lock`, sem validação de argumento que deva virar Task faulted, e sem `foreach`/`await foreach`. Em qualquer outro caso mantenha `async`/`await` — o custo da máquina de estado é irrelevante fora de caminho quente medido.* O sinal 🟡 pode ficar, mas a coluna de correção precisa dessa condição, senão a linha produz bug.

### B2 🔴 A ordem das correções do deadlock legado põe a mitigação insegura antes da solução

**Local:** `smells-legado.md`, "O deadlock de sync-over-async", lista "Correções, em ordem de preferência".

Hoje: (1) `await` até a borda; (2) **`ConfigureAwait(false)` em toda a biblioteca**; (3) versão sincrônica de verdade.

Dois problemas graves com o #2 na posição #2.

**Não resolve o modo de falha que derruba produção.** `ConfigureAwait(false)` elimina o deadlock por contexto, mas a thread bloqueada **continua bloqueada**. O pool continua sendo consumido, a taxa de injeção continua sendo ~1–2 threads/s, e sob rajada o app ainda vai a 503 — exatamente o que a própria seção descreve ("sob carga o pool de threads esgota e a aplicação inteira para de responder"). Apresentado como correção #2, o revisor conclui que o 🔴 foi resolvido quando o pior cenário sob carga permanece intacto. O documento diz "é mitigação, não solução" — mas então não deveria estar acima da solução real.

**Introduz um 🔴 que o próprio documento cataloga.** Depois de `ConfigureAwait(false)`, a continuação **não volta ao contexto da requisição** — e portanto `HttpContext.Current` fica `null`. Isso é literalmente a linha `HttpContext.Current após await | 🔴 | Pode ser null` da seção "ASP.NET: acoplamento com o pipeline web", três seções abaixo. Aplicar a mitigação #2 em toda a biblioteca de um sistema legado que usa `HttpContext.Current` (o caso normal) troca deadlock por `NullReferenceException` disperso. Nada no documento avisa.

**Ordem sugerida:**

1. `await` até a borda (com o requisito de `httpRuntime targetFramework` — ver D1). É a correção.
2. **Versão sincrônica de verdade**, se existir. Segura, previsível, sem thread desperdiçada em espera.
3. Se realmente não é possível agora: **descarregar para thread sem contexto** — `Task.Run(() => ServicoAsync()).GetAwaiter().GetResult()` — ou `JoinableTaskFactory` (`Microsoft.VisualStudio.Threading`), que é a solução documentada para sync-over-async obrigatório. Custa uma thread por chamada, então nunca em caminho quente, e deve entrar com comentário e data de remoção.
4. `ConfigureAwait(false)` na biblioteca como **complemento** de higiene, com o aviso explícito: perde `HttpContext.Current` na continuação, capture o que precisa antes do primeiro `await`.

### B3 🔴 `SemaphoreSlim.WaitAsync` recomendado como substituto direto de `lock`, sem as três armadilhas

**Local:** ambos os documentos, linha `lock` em volta de `await` / `await` dentro de `lock`, coluna de correção: `SemaphoreSlim.WaitAsync()`.

A recomendação é certa no destino e perigosa na forma, porque `SemaphoreSlim` não é um `lock`.

**1. `SemaphoreSlim` não é reentrante; `lock`/`Monitor` é.** Um caminho que hoje reentra o mesmo lock na mesma thread (A chama B que chama A) funciona com `lock` e **deadlocka para sempre** com `SemaphoreSlim(1,1)`. Conversão mecânica de `lock` para semáforo em código legado com chamadas aninhadas é uma das formas mais rápidas de travar um serviço em produção. O review precisa exigir a verificação de reentrância antes de aprovar a troca.

**2. O `Wait` tem que ficar fora do `try`.** O bug mais comum com `SemaphoreSlim`, e nenhum dos dois documentos menciona:

```csharp
// ERRADO: se WaitAsync é cancelado, Release() libera uma permissão nunca adquirida
try
{
    await _gate.WaitAsync(ct);
    await FazerTrabalhoAsync();
}
finally
{
    _gate.Release();     // SemaphoreFullException, ou pior: exclusão mútua deixa de existir
}

// CERTO
await _gate.WaitAsync(ct);
try
{
    await FazerTrabalhoAsync();
}
finally
{
    _gate.Release();
}
```

O modo de falha silencioso é o pior: o contador do semáforo sobe acima do inicial, e a partir daí **duas threads entram na região crítica** sem nenhuma exceção visível.

**3. Ciclo de vida.** `SemaphoreSlim` é `IDisposable`. Um `ConcurrentDictionary<TKey, SemaphoreSlim>` para lock por chave — padrão comum em cache e em idempotência — cresce sem limite e nunca descarta (e o factory do `GetOrAdd` pode criar mais de um semáforo para a mesma chave, ver C6, e aí a exclusão mútua não existe). Precisa de política de remoção ou contagem de referências.

### B4 🟠 `ConcurrentBag` como primeira correção para coleta de resultados

**Local:** `dotnet-moderno.md`, "Async e concorrência".

> `List<T>` sendo populada por várias tasks | 🔴 | ... | `ConcurrentBag`, ou coletar resultados de `WhenAll`

O diagnóstico é 🔴 correto. A ordem das correções está invertida. `ConcurrentBag<T>` é otimizado para o caso **produtor-consumidor na mesma thread** (mantém uma fila thread-local por thread e rouba de outras threads no dreno), tem ordem indefinida, e `Count`/enumeração são caros. Para "juntar N resultados de N tasks" ele é a ferramenta errada e frequentemente mais lento que a alternativa trivial — além de virar cargo cult ("é concorrente, logo é a resposta").

Ordem correta:

1. **`var resultados = await Task.WhenAll(tasks);`** — não existe coleção compartilhada, logo não existe problema de concorrência. Resolve a maioria dos casos e é o que o documento coloca por último como "ou".
2. Array pré-dimensionado com índice por tarefa (`resultados[i] = ...`) quando é preciso preservar posição — escritas em índices distintos de um array são seguras.
3. `Parallel.ForEachAsync` com `MaxDegreeOfParallelism` quando há muitos itens (ver C10).
4. `ConcurrentQueue<T>` se realmente é preciso um sink compartilhado com ordem FIFO.
5. `ConcurrentBag<T>` só no cenário para o qual foi desenhado.

### B5 🟠 "Cancelamento não é erro: não logue `OperationCanceledException` como falha"

**Local:** `dotnet-moderno.md`, "CancellationToken".

A intenção é boa (não poluir o log de erro com cliente que desistiu), mas escrita como regra absoluta ela faz o time **engolir falhas reais**, e é assim que se perde visibilidade de incidente:

- **timeout de `HttpClient` lança `TaskCanceledException`**, que é `OperationCanceledException` — com `InnerException` `TimeoutException` desde .NET 5. Filtrar por tipo transforma "a dependência está fora do ar" em silêncio absoluto;
- um **`CancellationTokenSource(timeout)` seu**, ou um CTS linkado com deadline, disparando é falha de SLA, não desistência de cliente;
- timeout por tentativa do handler de resiliência aparece como cancelamento; só o timeout total vira `TimeoutRejectedException`;
- `SaveChangesAsync` cancelado no meio pode deixar **efeito colateral parcial** (chamada externa feita, commit não) — precisa de log de erro, não de silêncio.

**Regra correta:** trate como não-erro somente quando o token que disparou é o token da requisição/`stoppingToken`:

```csharp
catch (OperationCanceledException ex) when (ct.IsCancellationRequested)
{
    log.LogInformation("Requisição abortada pelo cliente");   // não é falha
}
catch (OperationCanceledException ex)
{
    // token diferente disparou: timeout nosso, ou dependência estourou
    log.LogError(ex, "Timeout em {Operacao}", nome);
}
```

E separe as métricas "cliente abortou" de "nós estouramos o tempo" — confundir as duas mascara degradação de dependência.

### B6 🟠 O exemplo de código de DI contradiz duas linhas 🔴 do próprio documento e tem bug latente

**Local:** `dotnet-moderno.md`, "Injeção de dependência e lifetimes", bloco `Reconciler`, rotulado "correto".

Como está, o exemplo é o modelo que os autores de PR vão copiar. Três problemas:

**1. Sem `try/catch` no loop.** A tabela "Background services" do mesmo arquivo marca isso 🔴. Combinado com A3 (default `StopHost`), a primeira falha transitória de banco **derruba a aplicação inteira**. O exemplo rotulado "correto" viola a regra mais grave que o documento estabelece.

**2. `using var scope` deveria ser `await using` + `CreateAsyncScope()`.** O `Dispose()` sincrônico de um escopo de DI **lança `InvalidOperationException`** se algum serviço resolvido nele implementar apenas `IAsyncDisposable` (a mensagem do runtime é explícita: use `DisposeAsync` para descartar o container). E para serviços que implementam ambos — `DbContext`, `DbConnection` — força descarte bloqueante de conexão. Contradiz também a linha `IAsyncDisposable descartado com using sincrônico` da seção "Descarte de recursos".

**3. `Task.Delay` em loop e OCE no shutdown.** `PeriodicTimer` (ou `TimeProvider.CreateTimer`) não acumula drift e cancela de forma limpa. E `Task.Delay(..., stoppingToken)` lança `OperationCanceledException` no shutdown: sem catch, **todo shutdown gracioso** é logado como falha de serviço.

Versão corrigida:

```csharp
public sealed class Reconciler(
    IServiceScopeFactory scopeFactory,
    ILogger<Reconciler> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using var scope = scopeFactory.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
                await ReconciliarAsync(db, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;                                  // shutdown, não é falha
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Falha na reconciliação; tentando no próximo ciclo");
                // não relança: relançar aqui derruba o host (StopHost é o default)
            }

            try
            {
                await timer.WaitForNextTickAsync(stoppingToken);
            }
            catch (OperationCanceledException) { break; }
        }
    }
}
```

### B7 🟠 "Remover a materialização" do `ToList()` não é transformação segura

**Local:** `dotnet-moderno.md`, "Performance e alocação".

> `ToList()` só para iterar uma vez | `Remover a materialização`

Remover `ToList()` muda **quando** a consulta executa, e isso quebra código em três situações comuns:

- o `IQueryable` é devolvido de dentro de um `using`/escopo de DI e enumerado depois que o `DbContext` foi descartado → `ObjectDisposedException` (intermitente, aparece só sob certos caminhos);
- há uma segunda consulta na mesma conexão enquanto o reader do primeiro `IAsyncEnumerable` está aberto → falha, a menos que MARS esteja habilitado;
- a sequência é enumerada mais de uma vez em algum caminho (log, `Count`, retry) → a consulta roda de novo, silenciosamente, e o ganho vira regressão.

Adicionar a condição: *"remova apenas quando a enumeração provadamente ocorre uma única vez e dentro do tempo de vida do contexto/conexão"*.

### B8 🟠 "Troque para `ValueTask`" sem as restrições convida a bug e a regressão

**Local:** `dotnet-moderno.md`, "Performance e alocação".

> `async` em método trivial de caminho quente | `ValueTask` quando o resultado costuma ser síncrono

A direção é certa e as restrições — que são duras — estão todas ausentes.

**Contrato de uso (violá-lo é comportamento indefinido, sem exceção clara e sem analyzer ligado por padrão para a maior parte):**
- só pode ser `await`ada **uma vez**;
- não pode ser `await`ada duas vezes, guardada em campo, ou cacheada;
- não pode ir para `Task.WhenAll`/`WhenAny` sem `.AsTask()` antes;
- não pode ter `.Result`/`.GetAwaiter().GetResult()` chamado antes de completar.

**A parte que causa regressão de performance:** um método `async ValueTask` que **de fato vai para o caminho assíncrono ainda aloca** — a máquina de estado é boxeada. O ganho de alocação existe **só** no caminho de conclusão sincrônica. Sem `[AsyncMethodBuilder(typeof(PoolingAsyncValueTaskMethodBuilder))]` não há ganho no caminho async, e `ValueTask` é um struct maior que a referência de `Task`, o que aumenta cópia. Trocar `Task` por `ValueTask` num método que quase sempre vai async é **puro custo**.

Regra a escrever: *`Task` por padrão em API pública. `ValueTask` só quando (i) o caminho sincrônico domina, medido, e (ii) os consumidores estão sob seu controle. Para o cenário canônico — cache hit sincrônico — considere `HybridCache`/`IMemoryCache` antes de mexer na assinatura.*

### B9 🟡 "`IDisposable` criado sem `using` 🔴" gera falso positivo

**Local:** `dotnet-moderno.md`, "Descarte de recursos".

Como regra absoluta, marca como 🔴 vários padrões corretos: factory que transfere a posse, disposable guardado em campo e descartado no `Dispose` do dono, `HttpClient` obtido de `IHttpClientFactory`, objetos cujo tempo de vida é do container de DI, `Task`, `CancellationTokenRegistration` devolvida para o chamador. O documento se preocupa explicitamente com credibilidade ("faz o review perder credibilidade"); esta é uma das linhas que a corrói. Qualificar: *"quando o escopo é o dono do recurso"*.

---

## (c) LACUNAS CRÍTICAS

### C1 🔴 Thread pool starvation não é tratado como tópico

Aparece como uma oração incidental numa célula de tabela. É o modo de falha de performance nº 1 em ASP.NET Core em produção e merece bloco próprio. Faltando:

- **Como se manifesta:** p99 subindo enquanto o CPU fica baixo e plano; fila de requisições crescendo; timeouts em cascata em dependências saudáveis; sintoma que se autoagrava (timeout → retry → mais bloqueio).
- **Por que é tão brusco:** depois de atingir `MinThreads` (default = nº de processadores), o pool injeta apenas ~1–2 threads por segundo. Uma rajada não é absorvida.
- **Como detectar:** `dotnet-counters monitor System.Runtime` observando `threadpool-thread-count`, `threadpool-queue-length` e `threadpool-completed-items-count`; `ThreadPool.PendingWorkItemCount`; no dump, muitas threads paradas em `Monitor.Wait`/`WaitOne` dentro de `Task.Result`.
- **Fontes a marcar em review, no caminho de requisição:** `.Result`/`.Wait()`/`GetAwaiter().GetResult()`, `Thread.Sleep`, `lock` mantido durante chamada de rede ou banco, `Task.Run` para I/O, `Parallel.For` com corpo bloqueante, `IO` síncrono (`File.ReadAllText`, `stream.Read`), `Dispose()` sincrônico de recurso async.
- **`ThreadPool.SetMinThreads` / `DOTNET_ThreadPool_MinThreads`:** analgésico que compra tempo em rajada previsível, nunca a correção. Deve ser dito, porque times descobrem sozinhos e param aí.
- **Deadlock em construtor estático:** o CLR mantém o lock do `cctor`; bloquear numa Task dentro de um `static` initializer trava independentemente de contexto, em qualquer host. Documentado pela Microsoft e ausente nos dois arquivos.

### C2 🔴 Semântica do `ArrayPool` — a linha existe, os riscos não

O documento diz `ArrayPool<T>` com `try/finally` e para aí. As três coisas que dão errado ficaram de fora, e uma delas é vazamento de dados.

- **O array vem maior que o pedido e NÃO vem zerado.** A doc da API é literal: *"The array returned by this method may not be zero-initialized"* e o pool *"may hand back a larger array than was actually requested"*. Quem usa `buffer.Length` em vez do tamanho pedido publica **lixo do inquilino anterior**: `new string(buffer)`, `response.Body.Write(buffer)`, `Encoding.UTF8.GetString(buffer)` ou `JsonSerializer.Deserialize(buffer)` vazam dados de **outra requisição** na resposta desta. Em contexto multi-tenant isso é achado de segurança, não de performance. Correto: `buffer.AsSpan(0, tamanhoPedido)` sempre.
- **Devolver duas vezes, ou usar após devolver, é "high-severity security issue"** — palavras da própria doc de `ArrayPool<T>.Return`: double-free e use-after-free, com corrupção de dados, vazamento e DoS. Na prática o bug entra por um `return`/`throw` no meio entre `Rent` e `Return`, ou por manter um `Memory<T>`/`Span<T>`/`ArraySegment` apontando para o buffer devolvido (muito comum quando o buffer é passado para um método async que continua depois). Este é o achado que mais aparece em review de `ArrayPool` e não está em nenhuma linha.
- **`Return(buffer, clearArray: true)`** quando o buffer conteve segredo, token, PII ou chave.
- **`ArrayPool<T>.Shared` não é solução de LOH por si.** Ele não faz pooling de arrays arbitrariamente grandes (acima de ~1 MB aloca direto). Para stream/serialização grande: `RecyclableMemoryStream`, `MemoryPool<T>`, `IBufferWriter<T>`/`ArrayBufferWriter<T>`.

### C3 🔴 `IAsyncDisposable` merece mais que uma linha 🟠

Uma linha (`IAsyncDisposable descartado com using sincrônico | 🟠 | await using`) para o que é hoje uma família de defeitos. Faltando:

- `scopeFactory.CreateAsyncScope()` + `await using` para escopos — e o fato de que `Dispose()` sincrônico de um escopo **lança** se algum serviço resolvido implementar somente `IAsyncDisposable` (ver B6). Isso eleva a gravidade acima de 🟠 nesse caso: é exceção em runtime, não ineficiência.
- Tipos que exigem `await using` no dia a dia: `DbContext`, `DbConnection`, `DbTransaction`, `DbDataReader`, `IAsyncEnumerator<T>`, `Utf8JsonWriter`, `Stream` (quando há flush pendente), `Timer`, `RateLimiter`, `ServiceProvider`.
- Classe com **campo** `IAsyncDisposable` deve implementar `IAsyncDisposable` (e o par `Dispose`/`DisposeAsyncCore` quando não é sealed) — a tabela cobre o caso `IDisposable` e não o async.
- `IAsyncDisposable` em singleton de DI só é descartado no shutdown do host — relevante para conexões e conexões persistentes.
- `await using` dentro de `await foreach`: sair do loop por `break` ou exceção precisa descartar o enumerador async, o que só acontece com o `await using` correto.

### C4 🔴 CancellationToken: cinco armadilhas ausentes, uma delas é vazamento de memória

A seção é boa no básico e não cobre nada disso.

- **CTS linkado precisa ser descartado.** `CancellationTokenSource.CreateLinkedTokenSource(a, b)` registra um callback no token pai. Se o CTS linkado não for descartado e o pai for de vida longa (`IHostApplicationLifetime.ApplicationStopping`, token de um singleton), **a registration fica enraizada no pai e acumula por requisição** — vazamento que cresce com o tráfego e é dificílimo de achar sem gcdump. Sempre `using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeoutCts.Token);`.
- **Nem tudo deve receber o token da requisição.** Contraponto obrigatório à regra "propague sempre": depois do **ponto sem volta** (chamada externa já efetivada, cobrança feita, mensagem publicada), passar o token da requisição para `SaveChangesAsync`/outbox/auditoria significa que **um cliente desconectando deixa o sistema inconsistente**. Nesses trechos use `CancellationToken.None` ou um CTS curto próprio, deliberadamente. Isso não está em nenhum dos dois documentos e é achado real e recorrente.
- **`[EnumeratorCancellation]`.** Num iterador `async IAsyncEnumerable<T> M([EnumeratorCancellation] CancellationToken ct)`, sem o atributo o token passado por `WithCancellation(ct)` é **silenciosamente ignorado**. É exatamente o "token aceito e não honrado" que a seção declara ser pior que não aceitar — e é invisível em code review sem conhecer o atributo.
- **`ct.Register(...)` devolve `CancellationTokenRegistration` descartável.** Não descartar em token de vida longa é o mesmo vazamento do CTS linkado.
- **`CancellationTokenSource` descartado + `Token`** → `ObjectDisposedException`; e `Cancel()` executa os callbacks **inline na thread que cancela** (uma exceção num callback propaga para quem chamou `Cancel`).
- **Timeout por iteração em `BackgroundService`** exige CTS linkado combinando `stoppingToken` com deadline; usar só `stoppingToken` significa que uma iteração travada nunca é interrompida.

### C5 🔴 Fire-and-forget e exceções não observadas: ausente do documento moderno

O documento legado tem a linha (`Task` sem `await`... 🔴); o moderno **não tem nenhuma**, embora o problema seja idêntico e mais comum em ASP.NET Core.

- `_ = ProcessarAsync();` ou `Task.Run(() => ProcessarAsync());` dentro de um endpoint: (i) o escopo de DI da requisição é descartado ao responder → `ObjectDisposedException` no `DbContext` no meio do trabalho; (ii) o trabalho morre no shutdown/reciclagem sem nenhum registro; (iii) a exceção fica **não observada** e é silenciosamente descartada — desde .NET 4.5 exceção não observada não derruba mais o processo, então o defeito é invisível por design.
- Padrão correto: `Channel<T>` limitado + `BackgroundService` consumidor (é literalmente o padrão que a Microsoft documenta como substituto de `QueueBackgroundWorkItem`), ou fila durável quando a perda é inaceitável; `IHostApplicationLifetime` para dreno gracioso.
- **`Task.WhenAll` relança apenas a primeira exceção** quando `await`ada. As demais só existem em `task.Exception` (`AggregateException`) e se ninguém olhar, desaparecem — inclusive falhas de itens diferentes de um lote. Merece linha própria, porque o documento recomenda `WhenAll` em duas seções.
- `Task.WhenAny` sem observar o perdedor → exceção não observada; e `WhenAny` com timeout **vaza** a task perdedora, que continua rodando.
- Rede de detecção: `TaskScheduler.UnobservedTaskException` logando em Warning.

### C6 🔴 `ConcurrentDictionary` é recomendado três vezes, sem nenhuma ressalva

Aparece como correção em `Campo mutável compartilhado`, em `List<T> populada por várias tasks` e na seção de estáticos do legado. Nenhuma das armadilhas está registrada.

- **`GetOrAdd(key, factory)` pode chamar o factory mais de uma vez.** Literal na doc da API: *"the `valueFactory` delegate is called outside the locks... `valueFactory` may be called multiple times, but only one key/value pair will be added to the dictionary"*, e *"you cannot trust that just because `valueFactory` executed, its produced value will be inserted into the dictionary and returned"*. Consequências em código real: factory caro executado N vezes (abre conexão, chama HTTP, compila expressão), **objetos descartáveis órfãos** (o `SemaphoreSlim` de B3 — se dois são criados, a exclusão mútua deixa de existir), efeito colateral duplicado (contador, log, envio). Correção: valor `Lazy<T>` — `dict.GetOrAdd(k, _ => new Lazy<T>(criar, LazyThreadSafetyMode.ExecutionAndPublication)).Value` — ou `HybridCache` quando o factory faz I/O (aí a proteção de stampede é o ponto).
- **`GetOrAdd`/`AddOrUpdate` não são atômicos** em relação às outras operações do dicionário.
- **`Count`, `Keys`, `Values`, `ToArray()` e `foreach` são caros:** tomam todos os locks internos ou produzem snapshot. Em caminho quente, `Count` num `ConcurrentDictionary` é um erro clássico.
- **Dicionário sem limite em singleton é vazamento.** Chaveado por usuário, tenant, id de pedido ou correlation id, cresce para sempre. Use `HybridCache`/`MemoryCache` com `SizeLimit` e expiração, ou política explícita de remoção.

### C7 🟠 `TaskCompletionSource` sem `RunContinuationsAsynchronously`

Ausente dos dois arquivos. Por padrão, `SetResult` executa as continuações de quem espera **inline, na thread que completou**. Efeitos, todos observados em produção:

- a latência de quem completa passa a depender de código arbitrário do consumidor (a doc da Microsoft diz: *"`Set` could block for an unpredictable amount of time"*);
- completar **dentro de um lock** roda continuação de terceiro com o lock tomado → deadlock e reentrância inesperada (a doc é explícita: *"Completing a TCS inside the lock runs synchronous continuations while the lock is held, which could cause deadlocks or unexpected reentrancy"*);
- em pipeline de produtores encadeados, stack dive e risco de stack overflow.

Regras para o checklist: sempre `new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously)`; complete **fora** de qualquer lock; garanta que **todo** caminho completa a TCS (inclusive cancelamento e exceção), senão quem espera fica pendurado para sempre; prefira `TrySetResult`/`TrySetException` quando há mais de um completador possível (`SetResult` lança se já completou). O mesmo vale para `ManualResetValueTaskSourceCore<T>.RunContinuationsAsynchronously`.

### C8 🟠 GC e memória: server vs workstation, LOH e false sharing — nada na seção de performance

A seção "Performance e alocação" tem oito linhas e nenhuma trata de GC ou de layout de memória.

**Server GC vs Workstation GC.** `Microsoft.NET.Sdk.Web` liga `ServerGarbageCollection` por padrão; console/worker fica em Workstation. Server GC cria um heap (e uma thread de GC) por core: throughput muito maior, **piso de memória muito mais alto**. Consequências para review:
- worker/sidecar com 1–2 cores e limite de memória baixo em container: Server GC parece leak e pode estourar o limite → considere `<ServerGarbageCollection>false</ServerGarbageCollection>` ou DATAS (`System.GC.DynamicAdaptationMode`, ligado por padrão desde .NET 9, que ajusta o número de heaps dinamicamente);
- API sob carga em máquina com muitos cores: manter Server GC;
- verificar `<ConcurrentGarbageCollection>` e se o limite do cgroup está sendo respeitado (`GCHeapHardLimitPercent`); um pod com limite de memória e Server GC sem DATAS é a receita mais comum de OOMKilled em .NET.

**LOH (Large Object Heap).** Qualquer alocação ≥ **85.000 bytes** vai para a LOH: coletada só em gen2, **não compactada por padrão** → fragmentação e RSS que sobe e não volta. Isso é ~21 mil `int`, ~42 mil chars de `string`, ou um `byte[]` de 83 KB. Sinais para marcar em review: `new byte[tamanhoGrande]`, `stream.ToArray()`, `MemoryStream` crescendo por duplicação, `File.ReadAllBytes` de arquivo grande, `string.Join`/`Concat` sobre coleção grande, `JsonSerializer.SerializeToUtf8Bytes` de payload grande, `List<T>` com capacidade grande crescendo por duplicação (as realocações intermediárias também vão para a LOH). Correções: `ArrayPool`/`MemoryPool`/`RecyclableMemoryStream`, `IBufferWriter<T>`, processar em chunks, streaming (ver C9), pré-dimensionar coleções conhecidas. Último recurso e apenas medido: `GCSettings.LargeObjectHeapCompactionMode`.

**False sharing.** Duas variáveis quentes escritas por threads diferentes na **mesma linha de cache de 64 bytes** fazem o throughput colapsar com CPU alto e nenhum lock aparente. Onde aparece em review: `long[] _contadoresPorThread`, campos mutáveis adjacentes num objeto quente, `Interlocked.Increment` num campo compartilhado no caminho de requisição, `ConcurrentQueue` com head/tail adjacentes numa implementação caseira. Correções: padding para linha de cache, um slot alinhado por thread, agregação thread-local com consolidação periódica, ou `System.Diagnostics.Metrics.Counter<T>` (que já resolve). Vale o par: `Interlocked` é melhor que `lock` para um contador, mas um único campo `Interlocked` muito quente é ele mesmo ponto de contenção.

### C9 🟠 Streaming de resposta e de payload: ausente dos dois documentos

Buffer completo é uma das causas mais frequentes de OOM sob carga, e não há uma linha sobre isso.

- **Bufferizar o resultado inteiro:** `ToListAsync()` de 200 mil linhas, `ReadAsStringAsync()` de um corpo de 100 MB, `ToArray()` de stream. O pico é **por requisição concorrente** — funciona no teste com um usuário e cai com dez.
- Padrões corretos: devolver `IAsyncEnumerable<T>` de Minimal API (`System.Text.Json` serializa em streaming); `Results.Stream`/`Results.File` para arquivo; `JsonSerializer.DeserializeAsyncEnumerable` para array grande de entrada; `IFormFile` grande → gravar direto em disco/blob, nunca `CopyTo(new MemoryStream())`; limite de tamanho em qualquer leitura de corpo externo.
- **`HttpCompletionOption.ResponseHeadersRead`** + `ReadAsStreamAsync()` quando se faz proxy ou parsing de resposta grande. Sem isso, `HttpClient` bufferiza **o corpo inteiro** antes de devolver o controle, e o `Timeout` do cliente cobre esse período. Ausente da seção de HttpClient.
- **A armadilha que acompanha o streaming, e que é achado real de review:** uma vez que a resposta começou, **não é mais possível mudar status code nem devolver `ProblemDetails`**. Uma exceção no meio do `IAsyncEnumerable` produz um **200 truncado** — o cliente recebe JSON inválido com sucesso aparente. Além disso, streaming direto do EF Core mantém a conexão do pool ocupada durante todo o envio da resposta, inclusive por cliente lento. Streaming exige decisão consciente sobre esses dois pontos.

### C10 🟠 Limite de concorrência e backpressure: dito sem como

O documento recomenda "`await Task.WhenAll(tasks)` com cuidado de limite de concorrência" e nunca diz como. `WhenAll` sem limite sobre uma coleção grande é 🔴 por si: dispara milhares de chamadas concorrentes a banco/HTTP, esgota o pool de conexões e derruba a dependência.

Faltando: `Parallel.ForEachAsync(fonte, new ParallelOptions { MaxDegreeOfParallelism = n, CancellationToken = ct }, async (item, ct) => ...)` como ferramenta idiomática desde .NET 6; `SemaphoreSlim` como gate (com as ressalvas de B3); `Channel<T>` com `BoundedChannelOptions` + `BoundedChannelFullMode.Wait` quando é preciso **backpressure** de verdade; `System.Threading.RateLimiting` para limite de saída; `Task.WhenEach` (.NET 9) para processar conforme completam.

**E o esgotamento que falta nos dois arquivos:** o pool de conexões ADO.NET/EF Core tem `Max Pool Size` **100** por padrão. Estourá-lo dá `InvalidOperationException`/timeout ("Timeout expired. The timeout period elapsed prior to obtaining a connection from the pool") após 15 s de espera. Em .NET, esse esgotamento é **muito mais comum** que socket exhaustion, e nenhum dos dois documentos o menciona. Causas a marcar: `WhenAll` sem limite, conexão não descartada, escopo de DI vivo além da requisição, sync-over-async segurando conexão, transação longa.

### C11 🟠 Cache não existe na seção de performance

`HybridCache` aparece como uma linha numa tabela de "C# moderno". Para um checklist de review de performance, faltam:

- **cache-aside com proteção de stampede**: `HybridCache` tem, `IMemoryCache` **não** — o cenário clássico de "a chave expirou e 5 mil requisições simultâneas foram todas ao banco" é invisível em teste e brutal em produção;
- **`MemoryCache` sem `SizeLimit`** (e sem `Size` nas entradas) cresce sem limite → OOM. Achado 🟠 frequente;
- output caching vs response caching vs `[ResponseCache]`: qual resolve o quê, e que output caching é o único que você controla no servidor;
- **cache de dado por usuário sob chave compartilhada** — vazamento de dados entre usuários; achado de **segurança**, não de performance, e o mais grave desta família;
- memoização por requisição quando a mesma consulta roda 5 vezes no mesmo pipeline;
- expiração absoluta **e** sliding juntas, e invalidação por tag.

### C12 🟠 HttpClient: o remédio do caso singleton e o retry inseguro por default

- **`PooledConnectionLifetime` nunca é mencionado.** A linha `HttpClient estático de longa duração | 🟠 | Não respeita mudança de DNS` é um diagnóstico sem cura. A correção documentada, se você mantém o singleton, é `new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(2) }` — é exatamente o que `IHttpClientFactory` faz por baixo ao rotacionar handlers. Sem isso a linha só empurra para a factory sem explicar o mecanismo.
- **`AddStandardResilienceHandler` faz retry em POST por padrão.** Confirmado na doc: *"By default, the standard resilience handler is configured to make retries for all HTTP methods"*, com aviso explícito de duplicação de dados. Isso **contradiz frontalmente** a linha 🔴 `Retry em operação não idempotente (POST de cobrança)` do mesmo documento. Como o documento recomenda o handler padrão como "forma idiomática" na frase seguinte, o checklist como está **induz ao 🔴 que ele mesmo proíbe**. Item obrigatório de review: `options.Retry.DisableForUnsafeHttpMethods()` (desliga POST, PATCH, PUT, DELETE, CONNECT) ou `DisableFor(HttpMethod.Post, ...)`, ou chave de idempotência.
- **`HttpClient.Timeout` mata o pipeline de resiliência.** O `Timeout` (100 s default) cobre a execução **inteira**, incluindo as retentativas. Defaults do handler padrão: 30 s total, 3 retries com backoff exponencial e jitter, 10 s por tentativa. Se alguém baixar `Timeout` para 5 s "para ser seguro", as retentativas nunca acontecem. Com o handler padrão, deixe `Timeout = Timeout.InfiniteTimeSpan` e controle o tempo pela pipeline.
- **`DelegatingHandler` é efetivamente singleton.** Os handlers são reaproveitados junto com a entrada do pool (~2 min), então injetar serviço `Scoped` num `DelegatingHandler` é **captive dependency** — variante específica que a seção de DI não cobre. Use `IHttpContextAccessor` ou `IServiceScopeFactory` dentro do handler.
- `HttpResponseMessage`/`HttpContent` precisam de descarte; a linha sobre `EnsureSuccessStatusCode()` diz o sintoma ("perde o corpo do erro") sem dizer a causa: leia o corpo **antes** de chamar, ou verifique `IsSuccessStatusCode` manualmente.
- HTTP/2: `MaxConnectionsPerServer` e `EnableMultipleHttp2Connections` para dependência de alto volume.

### C13 🟡 Armadilhas menores que aparecem em review real e não estão em nenhum dos dois arquivos

- **Async-over-sync**: `Task.Run(() => MetodoBloqueante())` dentro de biblioteca para "oferecer API async". Consome uma thread por chamada e engana o chamador; em ASP.NET é pior que chamar o método síncrono direto. Distinto da linha `Task.Run para embrulhar I/O`, que trata do inverso.
- **Duplo-check locking sem `volatile`/`Volatile.Read`**: não reproduz em x86/x64 e reproduz em **ARM64** (Graviton, Ampere, Apple silicon), que hoje é produção comum. Merece linha, porque o modelo de memória mais fraco tornou um bug teórico em bug real.
- **`lock` mantido durante chamada externa** (HTTP, banco, arquivo) — nem precisa de `await`: serializa todas as requisições atrás de uma chamada de rede.
- **`AsyncLocal<T>`/`ExecutionContext`**: o contexto é capturado no `await` e é copy-on-write, então mutação depois do `await` não propaga para o chamador; `AsyncLocal` em singleton retém contexto e vaza.
- **Polling com `Task.Delay` em loop** onde cabia um sinal (`Channel`, `TaskCompletionSource`, `PeriodicTimer`).
- **Alocação de string em caminho quente**: `Split`, `Substring`, `ToLower()` para comparar, `string.Format` em loop → `AsSpan`, `SearchValues<char>` (.NET 8), `string.Create`, `StringComparison.Ordinal`.
- **Boxing no logging estruturado**: `LogInformation("... {Id}", id)` faz boxing dos value types num `object[]` a cada chamada. Em caminho quente, `[LoggerMessage]` (source-generated) e guarda `IsEnabled`. Relevante porque a seção de logging pede parâmetros nomeados sem mencionar o custo.
- **Enumerador struct perdido**: tipar `List<T>` como `IEnumerable<T>` faz boxing do enumerador e dispatch por interface a cada `foreach`. Conecta com A5/A6.
- **`System.Text.Json` por reflexão em caminho quente** → `JsonSerializerContext` (source generator); obrigatório para AOT/trimming.
- **`DateTime.UtcNow` em loop quente** → `Stopwatch.GetTimestamp()`/`Environment.TickCount64`.
- **Como medir.** O documento diz corretamente "otimização sem medição é aposta" e **nunca diz como medir**. Para um skill de review isso é lacuna estrutural: falta exigir evidência. Mínimo a acrescentar: BenchmarkDotNet com `[MemoryDiagnoser]` para micro; `dotnet-counters` para thread pool, GC e alocação em runtime; `dotnet-trace`/`dotnet-gcdump` para caminho quente e retenção; e a regra de review de pedir número antes/depois para qualquer mudança de performance 🟠, além de rejeitar micro-otimização sem número.

---

## (d) LEGADO .NET Framework 4.x

### D1 ✅ A exigência de `httpRuntime targetFramework="4.5"` está CORRETA — com duas precisões e um aviso

**Local:** `smells-legado.md`, correção 1 do deadlock.

> "Verifique que o `web.config` tem `<httpRuntime targetFramework="4.5" />` ou superior, senão o comportamento de contexto assíncrono não é o esperado."

**Correto e é um dos melhores itens do documento** — quase ninguém lembra dele, e sem ele a correção nº 1 falha de formas confusas. Precisões que fortalecem o item:

- O switch subjacente é `<add key="aspnet:UseTaskFriendlySynchronizationContext" value="true" />` em `appSettings`; declarar `httpRuntime targetFramework="4.5"` ou superior o liga implicitamente. Vale citar o app setting porque é o que se procura quando o `web.config` foi herdado de um `machine.config`/config pai.
- **Dizer qual é o sintoma sem ele**, porque não é deadlock: sem o contexto task-friendly, ASP.NET usa `LegacyAspNetSynchronizationContext`, e o resultado é **corrupção silenciosa** — `HttpContext.Current` inconsistente ou `null` após o `await`, a requisição podendo ser finalizada antes do trabalho assíncrono terminar, e `NullReferenceException` erráticas. Um revisor que espere "vai travar" não vai reconhecer o sintoma.

**Aviso ausente e importante:** `httpRuntime targetFramework` é um **switch de quirks em lote**, não uma linha isolada. Ligá-lo altera de uma vez vários comportamentos de 4.5 além do contexto assíncrono (validação de requisição, geração/validação de `MachineKey`, tratamento de cultura, comportamentos de `Request`/`Response`). Não é edição de passagem num sistema legado: exige rodada de regressão. Como está — "verifique que tem 4.5 ou superior" — o texto convida a adicionar a linha no PR e seguir, o que já derrubou muitos sistemas em produção. Sugestão: *"se estiver ausente, tratar como mudança própria, com teste de regressão; não incluir junto do refactor de async."*

### D2 ❌ `QueueBackgroundWorkItem`: versão errada e nenhuma das ressalvas

Ver A4 para a versão (**4.5.2**, não 4.5). As ressalvas ausentes, todas relevantes para review:

- É limitado por `HostingEnvironment.ShutdownTimeout` (deriva de `shutdownTimeLimit` no applicationHost.config, **90 segundos** por padrão). Trabalho mais longo é **abortado**.
- Ele apenas **atrasa** o shutdown do AppDomain. Não sobrevive a crash do pool, a `Stop` forçado do IIS, nem a reciclagem inesperada. A frase do documento "o IIS pode reciclar o pool e o trabalho desaparece sem log" continua parcialmente verdadeira **depois** da correção sugerida.
- **Não flui `ExecutionContext` nem `SecurityContext`** (documentado na própria API): `Thread.CurrentPrincipal` e afins não chegam ao callback. Bug de autorização esperando acontecer se o trabalho depende do usuário atual.
- Não há `HttpContext` dentro do work item.
- Exceção não tratada dentro dele ainda derruba o processo.
- O `CancellationToken` fornecido é sinalizado no shutdown — e precisa ser respeitado, senão o timeout de 90 s é atingido de todo jeito.

Consequência para o documento: a alternativa que ele já cita — "ou melhor, uma fila durável e um serviço fora do web" — deveria ser a **recomendação primária**, com `QueueBackgroundWorkItem` como paliativo explicitamente limitado a trabalho curto, idempotente e cuja perda é tolerável.

### D3 ❌ Falta o pré-requisito de async em Web Forms: `Async="true"` + `RegisterAsyncTask`

Nem a seção de async nem a de Web Forms mencionam, e é o bloqueio nº 1 para quem tenta aplicar a correção nº 1 num sistema Web Forms:

- a página precisa de `<%@ Page Async="true" ... %>`; sem isso, `await` num `Page_Load` lança `"An asynchronous operation cannot be started at this time."`;
- o padrão correto é `RegisterAsyncTask(new PageAsyncTask(MetodoAsync))` no `Page_Load`, não `async void Page_Load`;
- `AsyncTimeout` na diretiva `@Page` é o que fornece o `CancellationToken` ao método assíncrono;
- em MVC clássico, o par é `AsyncTimeoutAttribute`.

Dado que o documento tem seção de Web Forms e trata sync-over-async como o defeito mais grave do legado, a ausência desse pré-requisito torna a correção principal inaplicável no cenário mais comum.

### D4 ❌ Falta `ServicePointManager.DefaultConnectionLimit` — o gargalo clássico de legado

Ausente dos dois documentos, e é a explicação mais frequente para "tornamos assíncrono e não ficou mais rápido" em `net4x`.

O limite de conexões simultâneas **por endpoint** no .NET Framework:
- **2** em aplicação não-ASP.NET (console, Windows Service) — default histórico do `ServicePointManager`;
- em ASP.NET com `autoConfig`, **12 × número de CPUs** (num quad-core, 48).

Acima disso as chamadas **serializam**, independentemente de quantas tasks você disparou. A doc oficial de async em ASP.NET 4.5 recomenda exatamente: ajustar `connectionManagement/maxconnection` no config, ou definir `System.Net.ServicePointManager.DefaultConnectionLimit` programaticamente no `Application_Start` do `global.asax`. Num documento de performance de legado, isso é lacuna de primeira ordem — e faz par com a linha existente sobre `ConnectionLeaseTimeout` na seção "Recursos e descarte", que trata do outro problema do mesmo objeto.

### D5 ❌ Falta a mitigação de starvation do legado: `SetMinThreads` / `processModel` / `MaxConcurrentRequestsPerCPU`

A própria seção do deadlock afirma que "sob carga o pool de threads esgota e a aplicação inteira para de responder", e não oferece nada para o intervalo entre descobrir o problema e terminar a migração para async.

Faltando: o pool injeta ~1–2 threads/s depois do mínimo, então uma rajada num app legado com sync-over-async produz **HTTP 503 "Server Too Busy"** antes de o pool acompanhar (o máximo default em 4.5 é 5.000 threads, e cada uma custa ~1 MB de stack — 5.000 threads é ~5 GB só de stack, número que a doc da Microsoft usa para argumentar contra sync). Mitigações a citar, sempre rotuladas como paliativo: `ThreadPool.SetMinThreads` no `Application_Start`, `<processModel minWorkerThreads="..." autoConfig="false">` no machine.config, e `MaxConcurrentRequestsPerCPU` (5.000 por default em 4.5). O aviso é obrigatório: aumentar mínimos troca 503 por consumo de memória e mais contenção — compra tempo, não corrige.

### D6 ⚠️ "Em console e em serviço Windows o mesmo código funciona" dá falsa confiança

**Local:** `smells-legado.md`, "O detalhe cruel".

O parágrafo está certo no ponto que quer fazer (o bug é dependente de host) e a palavra "funciona" é forte demais, num texto cujo objetivo é justamente fechar essa armadilha. Sem contexto não há deadlock **por contexto**, mas:

- **starvation do pool continua valendo** sob concorrência, em console e em serviço Windows igualmente;
- **deadlocka em WinForms/WPF** (ali sim há afinidade de thread real);
- **deadlocka em teste xUnit v2**, que instala `AsyncTestSyncContext` — ou seja, "passou nos testes" não é evidência de que está seguro (xUnit v3 removeu o contexto, o que muda a conclusão conforme a versão);
- **deadlocka em construtor estático** em qualquer host, pelo lock do `cctor`.

Redação sugerida: *"em console e em serviço Windows não ocorre o deadlock por contexto, porque não há `SynchronizationContext` — mas o código continua consumindo uma thread do pool por chamada bloqueada, e continua sujeito a starvation sob concorrência. Em WinForms/WPF, em teste xUnit v2 e dentro de construtor estático, ele deadlocka também."*

### D7 ⚠️ Diferença entre `.Result`/`.Wait()` e `.GetAwaiter().GetResult()` não registrada

Os dois documentos tratam os três como equivalentes (correto quanto à gravidade 🔴), mas a diferença é relevante em review de tratamento de exceção: `.Result` e `.Wait()` embrulham em `AggregateException`; `.GetAwaiter().GetResult()` **relança a exceção original** com stack preservado. É a resposta para "por que meu `catch (SqlException)` parou de funcionar depois que troquei `await` por `.Result`", e é o motivo pelo qual `GetAwaiter().GetResult()` é o menos ruim dos três quando não há alternativa (correção nº 3 de B2).

### D8 ⚠️ `async void` no legado: "derruba o worker process" não é o sintoma típico

Ver A9. No ASP.NET clássico com contexto task-friendly, a exceção é relançada no `SynchronizationContext` da requisição e tipicamente **falha aquela requisição**; o sintoma canônico de `async void` numa página ou módulo é `"An asynchronous module or handler completed while an asynchronous operation was still pending."` O crash de worker process é o que se obtém **sem** contexto capturado (callback de `Timer`, thread de background criada à mão, `ThreadPool.QueueUserWorkItem`). Continua 🔴; nomear o sintoma por caso é o que torna o achado defensável na discussão do PR.

### D9 ⚠️ "Task esquecida": correto, mas falta o detalhe que explica o silêncio

**Local:** `smells-legado.md`, `Task` sem `await` e sem `return`.

> 🔴 | `Exceção fica não observada, e o trabalho pode não terminar`

Correto. Falta o que explica por que ninguém percebe: **desde .NET 4.5, exceção não observada não derruba mais o processo** na finalização (em 4.0 derrubava). Ela é simplesmente descartada. Para tornar visível em legado: assinar `TaskScheduler.UnobservedTaskException` e, em ambiente de dev/teste, `<ThrowUnobservedTaskExceptions enabled="true" />` no app.config. Sem isso, a linha diz "fica não observada" sem dar ao revisor nenhuma forma de provar que está acontecendo.

### D10 ❌ Falta `<gcServer enabled="true" />` para serviço legado

Ausente. ASP.NET sob IIS já roda com Server GC por default (definido no `aspnet.config`), mas um `net4x` console ou Windows Service fica em **Workstation GC**. Um worker legado carregado, em máquina com muitos cores, pode ficar limitado por GC por falta de uma linha no `app.config`. Faz par com C8 e é o tipo de achado de alto retorno e baixo risco que um review de performance de legado deveria produzir.

### D11 ❌ Falta a nota de disponibilidade de API em `net4x`

O documento legado remete ao moderno em vários pontos, o que cria risco de o revisor recomendar API inexistente na plataforma. Vale uma nota curta:

- **existem** em 4.5+: `SemaphoreSlim.WaitAsync`, `ConcurrentDictionary`, `CancellationToken`/CTS linkado, `ConfigureAwait`, `Task.Delay`, `TaskCompletionSource` com `RunContinuationsAsynchronously` (4.6+), `MemoryCache`;
- **não existem** sem pacote extra: `IAsyncDisposable`/`await using` e `IAsyncEnumerable` (`Microsoft.Bcl.AsyncInterfaces`), `ArrayPool<T>`/`Span<T>` (`System.Buffers`, `System.Memory`), `Channel<T>` (`System.Threading.Channels`), `ValueTask` (`System.Threading.Tasks.Extensions`);
- **não existem de forma alguma** em `net4x`: `PeriodicTimer`, `TimeProvider` (há backport parcial via `Microsoft.Bcl.TimeProvider`), `System.Threading.Lock` (.NET 9), `Parallel.ForEachAsync`, `HybridCache`, `System.Threading.RateLimiting`.

---

## Resumo de prioridade

Se for corrigir em ordem de retorno:

| # | Achado | Onde | Por quê primeiro |
|---|---|---|---|
| 1 | **A1** — mecanismo do deadlock (lock de exclusão, não afinidade de thread) | `smells-legado.md`, seção do deadlock | O documento se propõe a ser a explicação de referência do defeito mais grave do legado, e explica o mecanismo errado |
| 2 | **B2** — ordem das correções do deadlock; `ConfigureAwait(false)` acima da solução real, e sem o aviso de `HttpContext.Current` null | idem | A mitigação recomendada deixa a starvation intacta e introduz um 🔴 catalogado no mesmo documento |
| 3 | **B1** — "remover `async` e devolver a `Task`" | `dotnet-moderno.md`, Async | Conselho 🟡 aplicado mecanicamente que produz `ObjectDisposedException` e exceção no lugar errado |
| 4 | **B3** — `SemaphoreSlim` como substituto de `lock` sem reentrância, sem `Wait` fora do `try`, sem ciclo de vida | ambos | Deadlock permanente ou perda silenciosa de exclusão mútua |
| 5 | **C12** + **A2** — retry em POST por default no handler padrão; `HttpClient.Timeout` matando a pipeline; timeout de 100 s; mecanismo do pool errado | `dotnet-moderno.md`, HttpClient | O checklist induz ao 🔴 que ele mesmo proíbe, e ensina o mecanismo errado |
| 6 | **A3** + **B6** — `StopHost` desde .NET 6; exemplo de DI sem `try/catch` e com `using` sincrônico de escopo | `dotnet-moderno.md`, DI e Background services | O exemplo rotulado "correto" viola duas linhas 🔴 do próprio documento e tem exceção em runtime latente |
| 7 | **C2** — `ArrayPool` não vem zerado e vem maior; devolver duas vezes é falha de severidade alta | `dotnet-moderno.md`, Performance | Vazamento de dado entre requisições, não só ineficiência |
| 8 | **A5**/**A6** — `Count()`/`Any()` contraditórios e ambos imprecisos | `dotnet-moderno.md`, Performance | Duas linhas adjacentes pedindo mudanças opostas destroem a credibilidade da tabela |
| 9 | **C1** + **C8** — starvation como tópico; GC server/workstation, LOH, false sharing | `dotnet-moderno.md`, Performance | A seção de performance não cobre nenhuma das causas dominantes de incidente |
| 10 | **A4**/**D2**/**D3**/**D4** — 4.5.2, ressalvas do QBWI, `Async="true"`, `DefaultConnectionLimit` | `smells-legado.md` | Uma API que não compila na versão citada, e o gargalo clássico do legado ausente |
