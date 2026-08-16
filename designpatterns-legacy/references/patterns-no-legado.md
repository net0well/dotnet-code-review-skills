# Design Patterns no legado

O catálogo é o mesmo, mas o cálculo de custo é diferente. No legado, todo padrão carrega um custo extra que não existe em projeto novo: **o risco de regressão do próprio refactor**. Um padrão só se justifica se reduzir risco futuro mais do que o risco que introduz agora.

Todo o código deste arquivo é compatível com **C# 5 em diante**, para funcionar em qualquer `net4x`. Onde uma versão mais nova permite escrever melhor, há nota indicando.

## Índice

- [O que vale e o que não vale](#o-que-vale-e-o-que-não-vale)
- [Adapter: o padrão mais valioso no legado](#adapter-o-padrão-mais-valioso-no-legado)
- [IClock: o adapter de maior retorno](#iclock-o-adapter-de-maior-retorno)
- [Strategy sem keyed services](#strategy-sem-keyed-services)
- [Decorator sem Scrutor](#decorator-sem-scrutor)
- [Consertar Singleton sem container](#consertar-singleton-sem-container)
- [Retrofit de injeção de dependência](#retrofit-de-injeção-de-dependência)
- [Repository sobre EF6 e ADO.NET](#repository-sobre-ef6-e-adonet)
- [Observer no legado](#observer-no-legado)
- [Facade para congelar subsistema](#facade-para-congelar-subsistema)

---

## O que vale e o que não vale

| Padrão | No legado | Motivo |
|---|---|---|
| **Adapter / anti-corruption layer** | Vale muito | Isola o que você não pode ou não quer mudar. Reduz risco imediatamente |
| **Facade** | Vale muito | Congela um subsistema bagunçado atrás de uma entrada única e testável |
| **Strategy** | Vale quando o `switch` comprovadamente muda | Se o `switch` não muda há anos, não vale o risco |
| **Decorator manual** | Vale para log, cache e auditoria | Wrap Method já é um Decorator por dentro, e não muda chamador |
| **Template Method** | Vale quando a herança já existe | Aproveita a estrutura em vez de redesenhar |
| **Repository** | Vale sobre ADO.NET; discutível sobre EF6 | Sobre ADO.NET dá seam de teste. Sobre EF6, o `DbSet` já é repositório |
| **Factory** | Vale se a escolha é dinâmica | Não vale para esconder um `new` |
| **State / tabela de transições** | Vale se há bug de status recorrente | O ganho é impedir estado inválido, o que é risco real |
| **Observer** | Cuidado | Em legado, `event` sem `-=` é vazamento clássico. Prefira chamada explícita |
| **Generic Repository** | Não vale | Sobre EF6 é indireção sem retorno, e costuma destruir performance |
| **Mediator** | Não vale sem pipeline | Adiciona indireção num sistema que já é difícil de navegar |
| **CQRS completo** | Não vale como refactor | Vale como forma de escrever *código novo* ao lado do legado |
| **Abstract Factory** | Raramente | Custo alto em interfaces, ganho raro |
| **Visitor** | Não | Cerimônia alta e hierarquia legada raramente é estável |
| **Clean Architecture completa** | Não como refactor | Vale como estrutura dos módulos novos, via Strangler Fig |

## Adapter: o padrão mais valioso no legado

Duas aplicações, ambas com retorno imediato.

**1. Isolar integração externa.** Se o DTO do fornecedor, o `HttpResponseMessage` ou o código de status do parceiro circulam pelo sistema, cada mudança do fornecedor espalha impacto. O adapter concentra a tradução num arquivo.

**2. Isolar o próprio legado.** Quando existe uma classe intocável (sem teste, sem autor disponível, com regra crítica), embrulhe-a numa interface que expressa o que o *código novo* precisa. O legado continua funcionando, e o código novo depende de uma interface limpa e mockável.

```csharp
// A interface é escrita a partir da necessidade do código NOVO,
// não a partir da forma do legado.
public interface ICalculadoraDeJuros
{
    decimal Calcular(decimal valor, int diasDeAtraso);
}

// O adapter é a única classe que conhece a bagunça do legado
public class CalculadoraDeJurosLegadaAdapter : ICalculadoraDeJuros
{
    private readonly CalculoFinanceiroManager _legado;

    public CalculadoraDeJurosLegadaAdapter()
    {
        _legado = new CalculoFinanceiroManager();
    }

    public decimal Calcular(decimal valor, int diasDeAtraso)
    {
        // traduz para o vocabulário esquisito do legado e volta
        var dto = new CalcDTO();
        dto.VLR = valor;
        dto.DIAS = diasDeAtraso;
        dto.TIPO = 3;                      // 3 = juros simples, segundo a doc de 2013

        var resultado = _legado.Processar(dto);
        return resultado.VLR_FINAL;
    }
}
```

Ganho concreto: a partir daqui, todo código novo é testável, e o dia em que o legado for substituído, muda uma classe.

## IClock: o adapter de maior retorno

`DateTime.Now` espalhado é o maior bloqueador de testabilidade em código legado, e a correção é barata.

**Verifique primeiro se dá para usar a abstração da plataforma.** `TimeProvider` está disponível em `net462+` pelo pacote `Microsoft.Bcl.TimeProvider`, e o `FakeTimeProvider` pelo `Microsoft.Extensions.TimeProvider.Testing`, ambos com alvo `netstandard2.0`. Em `net472+` com `PackageReference` isso é preferível a escrever abstração própria, porque alinha o legado com o código novo, dispensa manter um fake caseiro, e o `FakeTimeProvider` já resolve timer e `Task.Delay`, o que um `IClock` de duas linhas não faz.

Só escreva o seu quando o pacote não for viável: alvo anterior a `net462`, ou projeto com `packages.config` onde acrescentar dependência transitiva custa caro.

```csharp
public interface IClock
{
    DateTime UtcNow { get; }
}

public sealed class SystemClock : IClock
{
    public DateTime UtcNow
    {
        get { return DateTime.UtcNow; }
    }
}

public sealed class FakeClock : IClock
{
    private DateTime _now;
    public FakeClock(DateTime inicio) { _now = inicio; }
    public DateTime UtcNow { get { return _now; } }
    public void Avancar(TimeSpan intervalo) { _now = _now.Add(intervalo); }
}
```

Se injetar ainda é caro no ponto em questão, use **Extract and Override** como passo intermediário (ver `refatorar-sem-testes.md`). Um método `protected virtual DateTime ObterAgora()` já torna a regra testável sem mudar nenhum chamador.

## Strategy sem keyed services

Não existe `AddKeyedScoped` em legado, mas o padrão funciona igual com um dicionário. Compatível com C# 5.

```csharp
public interface ICalculoFrete
{
    string Codigo { get; }
    decimal Calcular(Pedido pedido);
}

public class FretePac : ICalculoFrete
{
    public string Codigo { get { return "PAC"; } }
    public decimal Calcular(Pedido pedido) { return pedido.Peso * 0.9m + 12m; }
}

public class CalculadoraDeFrete
{
    private readonly Dictionary<string, ICalculoFrete> _porCodigo;

    public CalculadoraDeFrete(IEnumerable<ICalculoFrete> estrategias)
    {
        _porCodigo = new Dictionary<string, ICalculoFrete>(StringComparer.OrdinalIgnoreCase);
        foreach (var e in estrategias)
            _porCodigo.Add(e.Codigo, e);
    }

    public decimal Calcular(Pedido pedido, string modalidade)
    {
        ICalculoFrete estrategia;
        if (!_porCodigo.TryGetValue(modalidade, out estrategia))
            throw new NotSupportedException("Modalidade indisponivel: " + modalidade);

        return estrategia.Calcular(pedido);
    }
}
```

Se não houver container que resolva `IEnumerable<ICalculoFrete>`, monte a lista à mão no ponto de composição. Continua sendo Strategy, e continua sendo testável.

**Passo seguro de migração do `switch`:** não apague o `switch` no primeiro commit. Extraia cada braço para uma classe, faça o `switch` chamar as classes novas, verifique em produção, e só então troque o `switch` pelo dicionário. Dois commits pequenos em vez de um grande.

## Decorator sem Scrutor

Duas formas, ambas sem depender de container moderno.

**Forma 1, Wrap Method.** Quando você não quer tocar em nenhum chamador. É a de menor risco.

```csharp
public class PedidoRepository
{
    public Pedido Obter(int id)
    {
        var pedido = ObterOriginal(id);
        // comportamento novo, isolado
        _log.Debug("Pedido " + id + " carregado");
        return pedido;
    }

    private Pedido ObterOriginal(int id) { /* corpo original, intocado */ }
}
```

**Forma 2, Decorator clássico com composição manual**, quando já existe interface.

```csharp
public class PedidoRepositoryComCache : IPedidoRepository
{
    private readonly IPedidoRepository _interno;
    private readonly ObjectCache _cache;

    public PedidoRepositoryComCache(IPedidoRepository interno, ObjectCache cache)
    {
        _interno = interno;
        _cache = cache;
    }

    public Pedido Obter(int id)
    {
        var chave = "pedido:" + id;
        var emCache = _cache.Get(chave) as Pedido;
        if (emCache != null) return emCache;

        var pedido = _interno.Obter(id);
        if (pedido != null)
            _cache.Set(chave, pedido, DateTimeOffset.UtcNow.AddMinutes(5));

        return pedido;
    }
}

// composição explícita no ponto de registro
IPedidoRepository repo = new PedidoRepository(conexao);
repo = new PedidoRepositoryComCache(repo, MemoryCache.Default);
repo = new PedidoRepositoryComLog(repo, logger);
```

`ObjectCache` e `MemoryCache.Default` vêm de `System.Runtime.Caching`. A ordem das camadas importa da mesma forma que no moderno, então documente com comentário.

## Consertar Singleton sem container

Padrão muito comum em legado: `Manager` estático com estado. A correção completa exige DI, mas há um passo intermediário de risco baixo que já destrava o teste: transformar o estático numa **fachada que delega para uma instância substituível**.

```csharp
public interface IParametroService
{
    string Obter(string chave);
}

public class ParametroService : IParametroService
{
    private readonly ConcurrentDictionary<string, string> _valores =
        new ConcurrentDictionary<string, string>();

    public string Obter(string chave)
    {
        string valor;
        return _valores.TryGetValue(chave, out valor) ? valor : null;
    }
}

// A fachada mantém os ~200 chamadores existentes funcionando,
// e permite substituir a implementação em teste.
public static class ParametroManager
{
    private static IParametroService _instancia = new ParametroService();

    // usado apenas por teste e pela composição da raiz
    public static void Configurar(IParametroService instancia)
    {
        _instancia = instancia;
    }

    public static string Obter(string chave)
    {
        return _instancia.Obter(chave);
    }
}
```

Diga ao autor que isto é **andaime, não destino**. O objetivo final é injetar `IParametroService` pelo construtor. Mas com essa fachada você consegue escrever teste hoje, sem tocar em duzentos chamadores, e migrar os chamadores aos poucos conforme forem sendo alterados por demanda.

Marque o `Configurar` com um comentário explicando que é ponto de composição e teste, para ninguém usá-lo como service locator no meio da regra.

## Retrofit de injeção de dependência

Introduzir DI de uma vez numa aplicação legada é o caminho mais rápido para um incidente, porque as falhas aparecem em runtime, longe do ponto de mudança. Proponha em quatro estágios, e cada um pode parar ali.

**Estágio 1, composição manual no ponto de entrada.** Sem container. No controller ou na página, monte o objeto explicitamente. Isso já expõe as dependências e permite teste da classe de baixo.

```csharp
// no controller, temporariamente
private readonly IPedidoService _servico;

public PedidoController()
    : this(new PedidoService(new PedidoRepository(new SqlConexao()), new SystemClock()))
{
}

public PedidoController(IPedidoService servico)   // usado pelo teste
{
    _servico = servico;
}
```

**Estágio 2, um container no ponto de entrada.** Use o que o projeto já tem, ou adote `Microsoft.Extensions.DependencyInjection` se o alvo for `net472+`. Registre apenas o que você já converteu para construtor. Configure o resolvedor de dependências do MVC 5 ou do Web API 2.

**Estágio 3, converter classes por demanda.** Toda vez que tocar numa classe por motivo de negócio, converta os `new` internos dela para parâmetros de construtor. Não abra frente própria para isso.

**Estágio 4, remover as fachadas estáticas.** Só quando os chamadores já forem poucos.

Ponto de atenção específico do legado: em Web Forms, páginas não são construídas por você, então injeção por construtor não funciona direto. Use `HttpContext.Current.Application` como composição, property injection no `Page_Init`, ou mantenha a fachada estática nas páginas e use construtor apenas nas classes de regra que você extraiu.

## Repository sobre EF6 e ADO.NET

**Sobre ADO.NET, geralmente vale.** O acesso a dados está espalhado em SQL inline, e concentrar isso numa classe por agregado dá seam de teste e reduz duplicação de SQL. Métodos com intenção de negócio, devolvendo tipos do domínio, não `DataTable`.

**Sobre EF6, avalie com cuidado.** O `DbSet` já é repositório e o `DbContext` já é unit of work. Vale um repositório se: houver query de negócio que merece nome, ou você precisar de seam porque não consegue testar de outra forma. Não vale se for para "abstrair o EF".

E nunca recomende esta forma, que aparece com muita frequência em legado:

```csharp
// anti-padrão: traz a tabela e filtra em memória
public IEnumerable<Pedido> GetAll()
{
    return _context.Pedidos.ToList();
}
// consumidor
var pendentes = _repo.GetAll().Where(p => p.Status == "PENDENTE");
```

Marque como 🔴 quando a tabela é grande. A correção é um método que filtra no banco.

## Observer no legado

Em `net4x` o Observer costuma aparecer como `event`, e o vazamento por falta de `-=` é um dos defeitos mais comuns em WinForms e WPF legados. Regras para o review:

- Objeto de vida longa inscrito num objeto de vida curta, ou o inverso, exige `IDisposable` removendo a inscrição.
- Em web, prefira **chamada explícita** a evento. O fluxo fica rastreável, e não há ciclo de vida ambíguo.
- Se a reação precisa de garantia de entrega, evento em memória é a ferramenta errada. Grave numa tabela de pendências e processe com um serviço separado, que é o padrão Outbox feito de forma simples.

## Facade para congelar subsistema

Técnica muito útil quando existe um subsistema bagunçado que você não vai reescrever mas quer parar de espalhar. Crie uma fachada que exponha só as operações que o resto do sistema realmente precisa, e estabeleça a regra de que ninguém mais chama o subsistema direto.

Ganho: o subsistema para de crescer em acoplamento, e no dia da substituição existe uma superfície pequena e conhecida para reimplementar. É o primeiro passo natural de um Strangler Fig, e por isso vale mesmo sem plano de migração definido.
