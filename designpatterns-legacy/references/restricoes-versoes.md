# Restrições: o que existe em cada versão

**Leia antes de escrever qualquer C# num review de legado.** Sugerir sintaxe que não compila no alvo é o erro mais destrutivo possível para a credibilidade do review, porque o autor descobre no build e passa a desconfiar de todo o resto.

## Regra de ouro

O .NET Framework é oficialmente suportado até **C# 7.3**. Versões mais novas da linguagem podem funcionar em `net4x` forçando `<LangVersion>`, mas não são suportadas pela Microsoft e algumas features quebram em runtime, não em compilação. Em review, **assuma C# 7.3 como teto** quando o alvo é `net4x`, e trate qualquer coisa acima como sugestão condicional e explicitamente marcada.

Se o `.csproj` não declara `<LangVersion>`:
- Projeto `net4x` no formato antigo com `packages.config`: assuma o padrão do compilador instalado, mas escreva de forma conservadora (C# 5 ou 6) e ofereça a versão mais moderna como alternativa.
- Projeto `net4x` no formato SDK: o padrão para `net4x` é C# 7.3.

## Matriz de recursos por versão

| Recurso | Desde | Observação para legado |
|---|---|---|
| `async`/`await` | C# 5 | Disponível na prática em todo `net45+` |
| Interpolação de string `$"{x}"` | C# 6 | Muito seguro de sugerir |
| `nameof` | C# 6 | Substitui string mágica em `ArgumentNullException` |
| Membro com corpo de expressão `=>` | C# 6 | Em C# 6 só métodos e propriedades; construtores e acessores só em C# 7 |
| `?.` null-conditional | C# 6 | |
| Inicializador de auto-propriedade | C# 6 | |
| Filtro de exceção `catch (Ex e) when (...)` | C# 6 | Excelente para não capturar o que não vai tratar |
| `out var` | C# 7.0 | |
| Tuplas `(int, string)` | C# 7.0 | **Requer o pacote `System.ValueTuple` em `net45` a `net462`.** Nativo em `net47+` |
| Pattern matching básico (`is T x`, `case T x:`) | C# 7.0 | |
| Função local | C# 7.0 | |
| `throw` como expressão | C# 7.0 | |
| Separador de dígitos `1_000` | C# 7.0 | |
| `in` parâmetro, `ref readonly` | C# 7.2 | |
| `private protected` | C# 7.2 | |
| Comparação de tuplas `==` | C# 7.3 | Último recurso oficialmente suportado em `net4x` |
| **Nullable reference types** | C# 8 | Funciona em `net4x` forçando `LangVersion 8.0`, mas não é suportado. Alguns atributos exigem polyfill |
| `switch` de expressão | C# 8 | Idem: compila em `net4x` com `LangVersion 8.0`, não suportado oficialmente |
| `using` declaration (`using var x = ...`) | C# 8 | Idem |
| Ranges e índices `x[1..^1]` | C# 8 | Exige tipos `Index`/`Range`, que não existem em `net4x` sem polyfill |
| `IAsyncEnumerable`, `await foreach` | C# 8 | Exige o pacote `Microsoft.Bcl.AsyncInterfaces` |
| Membro padrão de interface | C# 8 | **Não funciona em `net4x`.** Depende de recurso do runtime |
| `record` | C# 9 | Exige polyfill de `IsExternalInit`. Não recomende em `net4x` |
| `init` | C# 9 | Mesmo polyfill |
| `new()` com tipo inferido | C# 9 | Compila com `LangVersion` forçado |
| Construtor primário | C# 12 | Não recomende em `net4x` |
| Collection expression `[]` | C# 12 | Não recomende em `net4x` |
| `field` keyword, extension members | C# 14 | Fora de questão em `net4x` |

## O que não existe no legado, e o que usar no lugar

Esta tabela é o coração de um review de legado útil. À esquerda o que você usaria no .NET moderno, à direita a versão que funciona.

| No moderno | No `net4x` |
|---|---|
| `TimeProvider` | **Existe em `net462+`** via o pacote `Microsoft.Bcl.TimeProvider`, e `FakeTimeProvider` via `Microsoft.Extensions.TimeProvider.Testing`. Os dois têm alvo `netstandard2.0`, então caem na ponte descrita abaixo. Em `net472+` com `PackageReference`, prefira a abstração da plataforma e o fake já testado. Só em `net45x`-`net461`, ou em projeto com `packages.config` onde adicionar pacote transitivo dói, crie `IClock` com `DateTimeOffset UtcNow { get; }` |
| `IOptions<T>` + `ValidateOnStart` | Classe de settings própria, populada de `ConfigurationManager` num único ponto, validada na inicialização (`Application_Start`), e injetada como interface |
| `IConfiguration` | `ConfigurationManager.AppSettings` / `ConnectionStrings`, atrás de uma interface própria para virar testável |
| `ILogger<T>` nativo | `Microsoft.Extensions.Logging` funciona em `net472+`. Se não puder, crie `IAppLogger` e adapte log4net/NLog atrás dela |
| `IHttpClientFactory` | `Microsoft.Extensions.Http` funciona em `net472+`. Se não puder, use um `HttpClient` estático por endpoint, com `ServicePointManager.ConnectionLeaseTimeout` ajustado para não ignorar DNS |
| `HybridCache` | `System.Runtime.Caching.MemoryCache`, ou `HttpRuntime.Cache` em web. Cuidado: sem proteção de stampede, então considere lock por chave |
| `record` | `class` com propriedades somente de leitura definidas no construtor. Se precisar de igualdade estrutural, implemente `Equals`/`GetHashCode` |
| `readonly record struct` | `struct` com campos `readonly` e `IEquatable<T>` implementado |
| Container nativo de DI | `Microsoft.Extensions.DependencyInjection` funciona em `net472+`, ou use o container que o projeto já tem (Unity, Ninject, Windsor, Autofac) |
| `System.Text.Json` | Funciona em `net472+` via pacote. Senão, `Newtonsoft.Json` |
| `Span<T>`, `Memory<T>` | Pacote `System.Memory` em `net461+` |
| `ExecuteUpdateAsync` / `ExecuteDeleteAsync` (EF Core) | EF6 não tem. Use `context.Database.ExecuteSqlCommand` com parâmetros, ou `Z.EntityFramework.Plus` |
| `AsNoTracking()` | Existe em EF6 também. Use |
| `AsSplitQuery()` | Não existe em EF6. Divida a consulta manualmente |
| `FrozenDictionary` | `ReadOnlyDictionary<TKey,TValue>` sobre um `Dictionary` |
| `Lock` (.NET 9) | `lock` com objeto privado, ou `SemaphoreSlim` para async |
| `WebApplicationFactory` | Não existe. Teste de caracterização em torno de seams, ou `OWIN TestServer` se for Web API 2 |
| Minimal API | MVC 5 controller, ou Web API 2 `ApiController` |
| `IExceptionHandler` | `IExceptionFilter` no MVC 5, `ExceptionFilterAttribute` no Web API 2, ou `Application_Error` no `Global.asax` |
| Middleware do ASP.NET Core | `IHttpModule`, `ActionFilter`, ou middleware OWIN se houver `Startup.cs` |
| `ProblemDetails` | Crie a classe de erro você mesmo, seguindo os mesmos campos. O contrato é mais valioso que a classe |

## A ponte que muita gente não conhece

Boa parte dos pacotes `Microsoft.Extensions.*` tem alvo `netstandard2.0`, portanto **funciona em .NET Framework**. Isso permite modernizar por dentro sem trocar de plataforma, e é frequentemente a recomendação de melhor retorno num review de legado:

- `Microsoft.Extensions.DependencyInjection`
- `Microsoft.Extensions.Logging`
- `Microsoft.Extensions.Configuration` (incluindo provider de JSON)
- `Microsoft.Extensions.Http` (`IHttpClientFactory`)
- `Microsoft.Extensions.Caching.Memory`
- `Polly`

Ressalva importante que você deve comunicar: `netstandard2.0` em `net461` funciona mas gera muitos avisos de binding e problemas de resolução de assembly. **`net472` ou superior é o mínimo confortável.** Se o projeto está em `net461` ou anterior, subir para `net472` é geralmente uma mudança pequena, sem alteração de código, e destrava tudo acima. Essa costuma ser a primeira recomendação de modernização com melhor relação custo-benefício.

## Como escrever a sugestão quando há dúvida de versão

Ofereça a forma conservadora como principal e a moderna como condicional:

```csharp
// Compatível com C# 5 em diante
public sealed class OrderService
{
    private readonly IOrderRepository _orders;
    private readonly IClock _clock;

    public OrderService(IOrderRepository orders, IClock clock)
    {
        if (orders == null) throw new ArgumentNullException("orders");
        if (clock == null) throw new ArgumentNullException("clock");
        _orders = orders;
        _clock = clock;
    }
}
```

E acrescente uma nota: "se o projeto estiver em C# 6 ou superior, `nameof(orders)` substitui a string literal; em C# 7 dá para usar `throw` como expressão e reduzir para `_orders = orders ?? throw new ArgumentNullException(nameof(orders));`".

Isso entrega valor nos dois cenários e demonstra que você levou a restrição a sério.
