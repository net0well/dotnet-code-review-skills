# Auditoria de metodologia (code-reviewer) — triagem

Arquivos vistos pelo auditor: `SKILL.md`, `solid-smells.md`, `scoring.md`.
**Ele NÃO viu `dotnet-moderno.md`, `arquitetura.md` nem `catalogo-patterns.md`.** Isso
invalida boa parte da seção (c), porque vários "faltando" estão nesses arquivos.

## ACEITOS — corrigir (ordem de gravidade)

### Bugs de projeto, graves

1. **O guarda de legado não pega legado.** `SKILL.md` manda procurar `<TargetFramework>`,
   mas csproj antigo (non-SDK) usa `<TargetFrameworkVersion>v4.x</TargetFrameworkVersion>`.
   O grep volta vazio e a skill moderna segue aplicando C# 12 em `net4x`, que é exatamente
   o cenário que o guarda existe para evitar. Corrigir para procurar `<TargetFrameworkVersion>`,
   `<TargetFrameworks>` (multi-target) e sinais indiretos (`packages.config`, `web.config`).

2. **Loop de lavagem entre orçamento e nota.** Orçamento de achados/extensão como "limite real"
   mais a regra "se não apontou problema concreto, a nota é alta" permite cortar um crítico
   para caber e subir a nota. Corrigir: o teto vale para 🟡 e 🟢; 🔴 e 🟠 nunca são limitados
   por orçamento. Se estourar, corta profundidade de explicação, nunca achado grave.

3. **Contradição de score com um 🔴 aberto.** Regra 3 diz "não passa de 5"; as faixas dizem
   "3 a 4: um crítico" e "1 a 2: críticos abertos". Três respostas para o mesmo caso.
   Fixar um teto único.

4. **Teste de preferência aplicado cedo demais.** "Dois sêniores discordariam" rebaixaria
   `async void`, sync-over-async e `AsNoTracking` a preferência. Aplicar o teste SOMENTE
   depois de excluir correção, concorrência, segurança e performance mensurável.

### Conselho perigoso

5. **`OperationCanceledException` não é sempre cancelamento.** `TaskCanceledException` herda dela
   e é o que `HttpClient` e EF lançam em **timeout**. Como está, a skill torna timeout de produção
   invisível. Correção: só é cancelamento com `when (ct.IsCancellationRequested)`; sem o filtro,
   é falha e loga como erro.

6. **"Exception como fluxo" acusaria guard clause legítima.** Como está, o revisor marcaria
   `ArgumentNullException.ThrowIfNull` e invariante de construtor, que são Framework Design
   Guidelines, e contradiz a própria seção de Validação. Escopar a "resultado de negócio esperado
   na camada de aplicação", isentando argument guards e invariantes de domínio.

7. **Remover dead code quebra em runtime.** Membro privado pode ser usado por reflexão:
   construtor sem parâmetros e setter privado do EF Core, `[JsonConstructor]`, serialização,
   DI por convenção, trimming. Exigir verificação antes de recomendar remoção.

8. **Remover `virtual`/interface em biblioteca publicada é breaking change** para consumidor
   fora da solution. Isentar superfície pública de pacote.

9. **Regra dos Três precisa de exceção.** Duplicar checagem de autorização, invariante ou
   cálculo monetário já é risco na segunda ocorrência.

10. **"Anemic Service: remover a camada"** sem blast radius. A classe pode ser a fronteira
    transacional, o ponto de autorização, ou seam de N chamadores.

### Erros factuais

11. `NotSupportedException` **não** é violação de Liskov por si: o BCL usa como contrato de
    operação opcional sondável (`Stream.Seek` com `CanSeek == false`, `ICollection<T>.Add`
    com `IsReadOnly`). Só é violação sem capability flag, e aí é ISP.
12. `HttpContext.Current` na heurística de DIP da skill **moderna**: é System.Web, não existe
    em ASP.NET Core. Trocar por `IHttpContextAccessor`/`HttpContext` vazando para a regra.
13. `System.Data.SqlClient` deprecado; o caso moderno é `Microsoft.Data.SqlClient`.
14. "HTTP range" não existe e são **cinco** classes de status. Trocar o exemplo de conjunto fechado.
15. Limiar de parâmetros inconsistente: tabela diz 4, catálogo diz 5+.
16. Penalizar interface com uma implementação contradiz o teste do aluguel (seam de teste) e
    port de Clean Architecture, que tem 1 adapter por design. Escopar.
17. Dependências no construtor: contar **colaboradores de negócio**, excluindo cross-cutting
    (`ILogger`, `IOptions`, `TimeProvider`).
18. Níveis de herança: contar só os níveis que o time possui, não os do framework.
19. "Dois atores pedindo mudança" não é verificável no código. Ancorar em evidência do arquivo.

### Vazamento de versão (a skill declara .NET 6 a 10 / C# 10 a 14)

20. O "padrão de qualidade da escrita" exige construtor primário e collection expression (C# 12),
    `required` (C# 11), `field` (C# 14) e `TimeProvider` (.NET 8). Em `net6.0`/C# 10 nada disso
    compila. O portão precisa ser **por feature**, não binário legado-vs-moderno.
21. Recomendações sem ressalva de versão: `FrozenDictionary` (.NET 8), `IExceptionHandler` e
    `ProblemDetails` nativo (ASP.NET Core 8), `WebApplicationFactory` (só ASP.NET Core).
22. `MockHttpMessageHandler` é pacote de terceiro, não BCL. Citar `DelegatingHandler` como via nativa.

### Lacunas reais (não cobertas em nenhum arquivo)

23. **Qualidade dos testes existentes**, não só testabilidade: asserção sobre implementação,
    ausência de caso negativo, `Thread.Sleep`, fixture mutável compartilhada, over-mocking.
    A skill pergunta "existe teste?" e nunca usa a resposta.
24. **Review de diff**: separar achado introduzido pela mudança de achado pré-existente, e
    checar chamadores antes de sugerir mudança de assinatura pública.
25. `double`/`float` para dinheiro; `struct` mutável; coleção mutável exposta por propriedade;
    parse/comparação sensível a cultura na skill **moderna** (hoje só existe na legada).

## REJEITADOS — já cobertos em arquivo que o auditor não leu

- Async/await, `async void`, sync-over-async, `CancellationToken` não propagado → `dotnet-moderno.md`
- Captive dependency e lifetimes de DI → `dotnet-moderno.md`
- Segurança (SQL injection, segredo, IDOR, CORS, hash, deserialização) → `dotnet-moderno.md`
- Performance e alocação → `dotnet-moderno.md`
- EF Core (N+1, `AsNoTracking`, `SaveChanges` em loop) → `dotnet-moderno.md`
- Nullable reference types → `dotnet-moderno.md`
- Disposal → `dotnet-moderno.md`
- Observabilidade e log estruturado → `dotnet-moderno.md`

**Porém procede o subponto:** `solid-smells.md` e o catálogo não referenciam esses arquivos,
então um revisor que só leia SOLID acha que a lista está completa. Adicionar ponteiro cruzado.
