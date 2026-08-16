# Defeitos típicos de .NET Framework

Catálogo dos problemas que aparecem em código `net4x`, com correção compatível com a plataforma. Separado em **defeito** (aponte sempre) e **datação** (só aponte se houver custo ativo hoje).

## Índice

- [O deadlock de sync-over-async](#o-deadlock-de-sync-over-async)
- [Async no legado](#async-no-legado)
- [ASP.NET: acoplamento com o pipeline web](#aspnet-acoplamento-com-o-pipeline-web)
- [Estado global e estáticos](#estado-global-e-estáticos)
- [Acesso a dados](#acesso-a-dados)
- [Entity Framework 6](#entity-framework-6)
- [Exceções](#exceções)
- [Segurança](#segurança)
- [Cultura, data e conversão](#cultura-data-e-conversão)
- [Recursos e descarte](#recursos-e-descarte)
- [Web Forms](#web-forms)
- [Datação: o que NÃO apontar como defeito](#datação-o-que-não-apontar-como-defeito)

---

## O deadlock de sync-over-async

Este é o defeito mais perigoso e mais específico do legado, e merece explicação completa no review porque muita gente não entende o mecanismo.

Em ASP.NET clássico existe um `SynchronizationContext` por requisição (`AspNetSynchronizationContext`) que permite **apenas uma thread por vez** naquele contexto. Quando você faz:

```csharp
// 🔴 deadlock esperando acontecer
public ActionResult Index()
{
    var dados = _servico.ObterDadosAsync().Result;   // ou .Wait()
    return View(dados);
}
```

a sequência é:

1. A thread da requisição **entra no contexto**, o que significa adquirir o lock exclusivo dele, e bloqueia no `.Result`.
2. O `await` interno completa e a continuação é **postada no contexto da requisição**.
3. O contexto admite apenas uma thread por vez, e o lock está tomado pela thread que está bloqueada. A continuação fica na fila e **nenhuma thread do pool consegue entrar** para executá-la.
4. Deadlock. O pedido trava até o timeout, e sob carga o pool esgota e a aplicação inteira para de responder.

Repare na distinção, porque ela muda a conclusão do review: **não é a mesma thread que é exigida, é a entrada exclusiva no contexto que está fechada.** O `AspNetSynchronizationContext` não tem afinidade de thread; ele é um lock de exclusão mútua associado à requisição. Em WinForms e WPF sim existe afinidade real, por causa do message pump, e aí a explicação "mesma thread" está correta.

Por que isso importa na prática: quem acredita na versão "mesma thread" conclui que jogar parte da cadeia em outra thread resolve, e isso é falso se os `await` internos continuarem capturando o contexto. E, do outro lado, explica por que `Task.Run(() => X()).GetAwaiter().GetResult()` **funciona** como escape, já que a cadeia passa a rodar sem contexto capturado. É escape, não solução: continua queimando uma thread do pool.

O detalhe cruel é que **em console e em serviço Windows o mesmo código funciona**, porque não há `SynchronizationContext`. Então o bug aparece só em produção web, e frequentemente só sob carga.

Correções, em ordem de preferência:

1. **`await` até a borda.** Torne a action `async Task<ActionResult>` e use `await`. É a correção correta.
   ```csharp
   public async Task<ActionResult> Index()
   {
       var dados = await _servico.ObterDadosAsync();
       return View(dados);
   }
   ```
   Verifique que o `web.config` tem `<httpRuntime targetFramework="4.5" />` ou superior, senão o comportamento de contexto assíncrono não é o esperado.

2. **`ConfigureAwait(false)` em toda a biblioteca**, se você não pode tornar o chamador assíncrono agora. Isso faz a continuação não tentar voltar ao contexto. Precisa estar em **todos** os `await` da cadeia, e basta um esquecido para o deadlock voltar. É mitigação, não solução.

3. **Versão sincrônica de verdade**, se existir. Melhor que sync-over-async.

Marque sempre como 🔴 quando encontrar `.Result`, `.Wait()` ou `.GetAwaiter().GetResult()` em código que roda sob ASP.NET.

## Async no legado

| Sinal | Grav. | Correção |
|---|---|---|
| `.Result` / `.Wait()` em contexto web | 🔴 | Ver seção acima |
| `async void` fora de event handler | 🔴 | `async Task`. Exceção em `async void` não é capturável e derruba o worker process |
| `ThreadPool.QueueUserWorkItem` ou `Task.Run` fire-and-forget em web | 🔴 | O IIS pode reciclar o pool e o trabalho desaparece sem log. Use `HostingEnvironment.QueueBackgroundWorkItem` (net45+), ou melhor, uma fila durável e um serviço fora do web |
| `Thread.Sleep` numa requisição | 🟠 | Bloqueia thread do pool. `await Task.Delay` se assíncrono, ou repense o fluxo |
| `lock (this)` ou `lock (typeof(X))` | 🟠 | Objeto de lock público permite deadlock causado por código externo. Use `private static readonly object` |
| `await` dentro de `lock` | 🔴 | Não compila com `lock`, e simular com `Monitor` corrompe o estado. `SemaphoreSlim.WaitAsync` |
| Ausência de `ConfigureAwait(false)` em biblioteca compartilhada | 🟠 | Risco de deadlock quando consumida por web ou UI |
| `Task` sem `await` e sem `return` (esquecida) | 🔴 | Exceção fica não observada, e o trabalho pode não terminar |

## ASP.NET: acoplamento com o pipeline web

| Sinal | Grav. | Problema | Correção |
|---|---|---|---|
| `HttpContext.Current` em regra de negócio | 🟠 | Impede teste e reuso fora de web; é `null` em thread de background | Interface própria (`ICurrentUser`, `IRequestContext`) implementada na camada web |
| `HttpContext.Current` após `await` | 🔴 | Pode ser `null` dependendo da configuração de contexto | Capturar o que precisa **antes** do primeiro `await`, e passar por parâmetro |
| `Session` acessada no domínio | 🟠 | Estado de apresentação vazando para a regra | Passar o dado como parâmetro |
| `Server.MapPath` em regra | 🟠 | Acopla a IIS | Injetar o caminho por configuração |
| `Request.QueryString` lido fora do controller | 🟠 | Idem | Parâmetro explícito |
| `Response.End()` ou `Response.Redirect(url)` sem `endResponse: false` | 🟠 | Lança `ThreadAbortException`, que aborta a thread e polui log | `Response.Redirect(url, false)` seguido de `Context.ApplicationInstance.CompleteRequest()` |
| Regra de negócio no `Global.asax` | 🟠 | Lugar errado, intestável | Mover para classe própria |
| `Application_Error` engolindo tudo sem log | 🔴 | Falhas invisíveis | Logar com contexto e deixar a página de erro tratar |

## Estado global e estáticos

| Sinal | Grav. | Correção |
|---|---|---|
| `public static class XManager` com estado mutável | 🔴 | Instância com interface, registrada no container. Se não houver container, use Parameterize Constructor como passo intermediário |
| `static Dictionary`/`List` mutável acessado por requisições | 🔴 | `ConcurrentDictionary`, ou lock explícito. Em web isso é concorrente por definição |
| `static DbContext` ou conexão compartilhada | 🔴 | Contexto por requisição. `DbContext` não é thread safe |
| Singleton com `Instance` estático e estado | 🔴 | Ver `patterns-no-legado.md`, seção Singleton |
| Cache em `static` sem expiração | 🟠 | `MemoryCache` com política, ou `HttpRuntime.Cache` |
| `ConfigurationManager.AppSettings["x"]` espalhado | 🟠 | Ler num único ponto para uma classe de settings, e injetar |
| `GC.Collect()` no código | 🟠 | Quase sempre piora. Remover, salvo caso medido e justificado |

## Acesso a dados

| Sinal | Grav. | Correção |
|---|---|---|
| SQL concatenado com valor de entrada | 🔴 | `SqlParameter`. Sem exceção, sem "mas é um id interno" |
| `SqlConnection`/`SqlCommand`/`SqlDataReader` sem `using` | 🔴 | `using` em todos. Conexão vazada esgota o pool |
| `SqlCommand` sem `CommandTimeout` em consulta pesada | 🟠 | Definir timeout explícito |
| Transação sem `using` ou sem rollback no `catch` | 🔴 | `using (var tx = conn.BeginTransaction())` com commit explícito |
| `DataTable` cruzando camadas até a view | 🟠 | Mapear para tipos na borda de dados. Não precisa ser tudo de uma vez, faça no fluxo que você está tocando |
| `dr["coluna"]` com string mágica repetida | 🟡 | Constantes, ou mapeamento num único ponto |
| `dr["valor"].ToString()` sem checar `DBNull` | 🔴 | Verificar `IsDBNull` |
| Concatenação de `IN (...)` em loop | 🔴 | Table-valued parameter, ou parâmetros gerados |
| Conexão aberta no começo do request e fechada no fim | 🟠 | Abrir o mais tarde e fechar o quanto antes |

## Entity Framework 6

| Sinal | Grav. | Correção |
|---|---|---|
| Lazy loading dentro de `foreach` | 🔴 | `Include()` explícito ou projeção. É N+1 |
| `Include("Cliente.Endereco")` por string | 🟡 | `Include(x => x.Cliente.Endereco)` com lambda, que o compilador valida |
| `.ToList()` antes do `.Where()` | 🔴 | Filtrar no `IQueryable` |
| Leitura sem `AsNoTracking()` | 🟠 | Existe em EF6, use em consulta de leitura |
| `SaveChanges()` dentro de loop | 🔴 | Um commit no fim |
| `DbContext` com vida de aplicação | 🔴 | Um por requisição, ou por unidade de trabalho |
| `context.Database.ExecuteSqlCommand` com interpolação | 🔴 | Parâmetros |
| `Skip/Take` sem `OrderBy` | 🟠 | EF6 exige ordenação para paginar, e sem ela o resultado é imprevisível |
| Validação de entidade dependendo de `DbEntityValidationException` | 🟠 | A mensagem padrão não diz qual propriedade falhou. Capturar e detalhar, ou validar antes |
| Migrations desabilitadas com banco alterado à mão | 🟠 | Documentar o estado real; considerar baseline |

## Exceções

| Sinal | Grav. |
|---|---|
| `catch { }` ou `catch (Exception) { }` vazio | 🔴 |
| `catch (Exception ex) { throw ex; }` | 🟠 (reseta o stack trace; use `throw;`) |
| `catch` que loga e continua como se tivesse sucesso | 🔴 |
| `throw new Exception("mensagem")` | 🟠 (impede tratamento específico) |
| Exceção usada para fluxo esperado | 🟠 |
| `catch (ThreadAbortException)` | 🟡 (sintoma de `Response.End`) |
| Detalhe da exceção exibido na tela | 🔴 |
| `Exception.Message` como única informação logada | 🟠 (perde stack e inner exception) |

## Segurança

| Sinal | Grav. |
|---|---|
| SQL concatenado | 🔴 |
| Senha com MD5, SHA1, ou hash sem salt | 🔴 |
| Senha ou connection string em `web.config` versionado sem criptografia | 🔴 |
| `validateRequest="false"` sem sanitização | 🔴 |
| `BinaryFormatter` desserializando dado externo | 🔴 (execução remota de código) |
| `requestValidationMode` reduzido para contornar erro | 🟠 |
| Cookie de autenticação sem `HttpOnly` e `Secure` | 🔴 |
| `<machineKey>` fixo e versionado no repositório | 🔴 Permite forjar ViewState e ticket de Forms Authentication, o que é execução remota de código. Este é o achado real, e é grave |
| `enableViewStateMac="false"` | 🟢 A configuração é **ignorada pelo runtime desde o .NET Framework 4.5.2**, o MAC é sempre aplicado. Não gaste atenção aqui; olhe o `<machineKey>` acima |
| Ausência de anti-forgery token em POST | 🔴 |
| Redirecionamento aberto (`Response.Redirect(Request["url"])`) | 🔴 |
| Falta de verificação de propriedade do recurso (IDOR) | 🔴 |
| `<customErrors mode="Off" />` em produção | 🔴 |
| TLS fixado no código (`ServicePointManager.SecurityProtocol = Ssl3` ou `Tls12`) | 🔴 Fixar versão é o defeito, inclusive fixar `Tls12`. Retargete para `net47+` e deixe `SystemDefault`, que herda a política do SO. `Tls13` não é viável nesta plataforma |
| Cookie sem `SameSite` | 🟠 Exige `net472+`, e não pega se o `httpRuntime targetFramework` do `web.config` for antigo |

### Senha no legado: o caminho óbvio é fraco

Recomendar "use um hash forte" não é acionável em `net4x`, porque o caminho que a plataforma oferece por padrão já é fraco. Seja específico:

| O que você vai encontrar | Problema | Correção viável |
|---|---|---|
| `Crypto.HashPassword` / `Microsoft.AspNet.Identity` v2 | PBKDF2 com **SHA1 e mil iterações**. Era aceitável em 2013, não hoje | Migrar para PBKDF2-SHA256 com contagem alta, ou bcrypt via `BCrypt.Net-Next` |
| `Rfc2898DeriveBytes` com SHA256 | Só existe a partir do **4.7.2**. Em alvo anterior o construtor com `HashAlgorithmName` não está disponível | Retargetar, ou usar bcrypt via pacote |
| MD5, SHA1, ou hash sem salt | 🔴 Sem discussão | Reescrever com rehash no próximo login bem-sucedido |

A migração de hash tem um detalhe que precisa entrar na recomendação: **você não pode reprocessar senhas que não tem**. O padrão é gravar a versão do algoritmo junto do hash e re-hashear no próximo login válido, mantendo os dois caminhos de verificação durante a transição.

### XSS no legado

Ausente do meu catálogo original e presente em praticamente todo sistema dessa idade. Atenção especial porque aqui o encoding **não** é automático como no Razor moderno.

| Sinal | Gravidade | Observação |
|---|---|---|
| `<%= valor %>` em ASPX ou view antiga | 🔴 **Não encoda.** O equivalente seguro é `<%: valor %>` (a partir do 4.0) ou `HttpUtility.HtmlEncode` |
| `@Html.Raw(...)` em MVC5 com valor de usuário | 🔴 Razor encoda por padrão, e `Html.Raw` desliga isso |
| `Response.Write` com entrada do usuário | 🔴 Encodar explicitamente |
| `Literal.Text` recebendo HTML de usuário | 🔴 Use `Literal.Mode = Encode`, ou `Label`/`HtmlEncode` |
| `validateRequest="false"` sem encoding no ponto de saída | 🔴 O filtro de request era proxy fraco e nunca substituiu encoding |
| `requestValidationMode` reduzido para contornar erro | 🟠 Costuma indicar que alguém desligou a proteção em vez de encodar |

## Cultura, data e conversão

Fonte silenciosa de bug em sistema brasileiro, e frequentemente ignorada em review.

| Sinal | Grav. | Correção |
|---|---|---|
| `decimal.Parse(texto)` sem cultura | 🔴 | `decimal.TryParse` com `CultureInfo` explícita. `"1,5"` e `"1.5"` mudam de valor conforme o servidor |
| `ToString()` de número ou data para persistir ou integrar | 🔴 | `ToString(CultureInfo.InvariantCulture)` com formato explícito |
| `DateTime.Now` para registrar acontecimento | 🟠 | `DateTime.UtcNow`, e converter só na exibição |
| `DateTime` sem `Kind` definido atravessando camadas | 🟠 | `DateTimeOffset`, ou UTC por convenção documentada |
| `int.Parse` de entrada de usuário | 🟠 | `TryParse` |
| `texto.ToLower() == outro.ToLower()` | 🟡 | `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`. Evita alocação e o problema do i turco |
| `ToUpper()` para comparar em banco | 🟠 | Impede uso de índice |

## Recursos e descarte

| Sinal | Grav. |
|---|---|
| `IDisposable` sem `using` | 🔴 |
| Classe com campo `IDisposable` sem implementar `IDisposable` | 🟠 |
| `StreamReader`/`FileStream` sem descarte no caminho de exceção | 🔴 |
| Inscrição em `event` sem `-=` em objeto de vida longa | 🔴 (vazamento clássico em WinForms/WPF) |
| `Timer` estático sem descarte | 🟠 |
| `HttpClient` ou `WebClient` novo por requisição | 🔴 (esgotamento de portas) |
| `HttpClient` estático eterno | 🟠 (ignora mudança de DNS; ajuste `ServicePointManager.ConnectionLeaseTimeout`) |

## Web Forms

Só aponte se o autor estiver mexendo ali. Web Forms funcionando é candidato natural à seção 🕰️.

| Sinal | Grav. | Correção |
|---|---|---|
| `Page_Load` com regra de negócio e acesso a dados | 🟠 | Extrair para classe própria (Sprout Class), que fica testável |
| Lógica dependendo de `IsPostBack` espalhada | 🟠 | Concentrar o fluxo |
| ViewState grande com objeto complexo | 🟠 | Payload cresce muito; guardar só identificador |
| `EnableViewState` desnecessário em grid grande | 🟡 | Desligar onde não precisa |
| Code-behind com 2000 linhas | 🟠 | Model-View-Presenter é o caminho de menor risco para tornar testável |
| Acesso a controle de UI dentro de método de regra | 🟠 | Passar valores, não controles |

## Datação: o que NÃO apontar como defeito

Estes itens são antigos, e está tudo bem. Colocá-los como problema desperdiça a atenção do autor e faz o review perder credibilidade. Se aparecerem, mencione na seção 🕰️ dizendo que estão adequados.

- `DataTable`, `DataSet` e `SqlDataAdapter` em código que funciona e não está sendo alterado.
- Web Forms, ASMX ou WCF em sistema estável. Migrar é projeto, não refactor.
- `Newtonsoft.Json` em vez de `System.Text.Json`. Newtonsoft é maduro e continua sendo escolha válida.
- log4net ou NLog em vez de `Microsoft.Extensions.Logging`.
- Unity, Ninject ou Castle Windsor como container. Funcionam.
- `string.Format` em vez de interpolação, quando não há problema de legibilidade.
- Comentário de cabeçalho com autor e data, se é convenção do time.
- `#region`, quando organiza um arquivo grande que você não vai quebrar agora.
- Nomenclatura em português. É consistente com o domínio e o time.
- Ausência de `async` em código sincrônico que funciona e não tem gargalo de I/O medido.
- `net472` em vez de `net48`. A diferença é irrelevante para a maioria dos casos.
