# SOLID, code smells e anti-padrões: heurísticas de detecção

O objetivo aqui é **mecânico**: sinais que você consegue verificar olhando o código, para que o review não vire opinião. Cada seção traz o sinal, por que é problema, a correção, e o falso positivo comum (importante, porque acusar violação onde não há destrói a credibilidade do review).

## Índice

- [SOLID com heurísticas](#solid-com-heurísticas)
- [Limites numéricos](#limites-numéricos)
- [Catálogo de code smells](#catálogo-de-code-smells)
- [Anti-padrões](#anti-padrões)
- [Tratamento de exceções](#tratamento-de-exceções)
- [Validação](#validação)
- [Nomenclatura](#nomenclatura)
- [Testabilidade: as seams](#testabilidade-as-seams)

---

## SOLID com heurísticas

### S — Single Responsibility

Formulação útil: **uma classe, um motivo para mudar**. Não é "uma classe faz uma coisa", que é vago e leva a classes anêmicas de um método.

**Heurísticas de detecção:**
1. Liste os atores que pedem mudança nessa classe (produto, DBA, time de integração, compliance). Dois atores diferentes pedindo mudança no mesmo arquivo é violação.
2. Conte os *tipos* de dependência no construtor. Misturar acesso a dados + envio de e-mail + regra de cálculo na mesma classe é sinal forte.
3. Procure a conjunção no nome do método: `SalvarEEnviarEmail`, `ValidarEProcessar`.
4. Se você não consegue descrever o que a classe faz em uma frase sem "e", provavelmente há duas classes ali.

**Falso positivo comum:** uma classe com muitos métodos pequenos e coesos em torno do mesmo conceito não viola SRP. Contar métodos não detecta SRP; contar **motivos de mudança** detecta.

### O — Open/Closed

**Heurística:** procure o histórico implícito. Se o arquivo tem um `switch` onde cada `case` corresponde visivelmente a uma feature entregue ao longo do tempo, toda feature nova editou código existente. Isso é a violação.

Sinal complementar: comentário do tipo `// TODO: adicionar novo tipo aqui também` ou `// não esqueça de atualizar o método X`. Isso documenta que a extensão exige edição em dois lugares, o que é shotgun surgery mais violação de OCP.

**Falso positivo:** um `switch` sobre um conjunto **fechado e estável** (dias da semana, os quatro status possíveis de um HTTP range) não viola OCP, porque não há extensão prevista. Pattern matching exaustivo sobre hierarquia fechada é bom design, não violação.

### L — Liskov Substitution

**Heurísticas de detecção:**
1. Implementação que lança `NotImplementedException` em membro da interface. Violação direta. **`NotSupportedException` é diferente:** o próprio BCL usa como contrato legítimo de operação opcional, desde que exista uma flag para sondar antes (`Stream.Seek` com `CanSeek == false`, `ICollection<T>.Add` com `IsReadOnly`). Sem a flag, quem consome não tem como saber, e aí o problema é interface grande demais, ou seja, ISP, não Liskov.
2. Override que **fortalece** a pré-condição (valida mais que a base) ou **enfraquece** a pós-condição (devolve menos garantia).
3. Consumidor com `if (x is TipoConcreto)` para tratar caso especial. Se precisa saber o tipo concreto, a abstração está mentindo.
4. Override que muda a semântica: base devolve lista vazia quando não acha, derivada lança exceção.

**Correção usual:** interface menor e mais honesta (ISP resolve LSP com frequência), ou composição em vez de herança.

### I — Interface Segregation

**Heurísticas:**
1. Implementações com métodos de corpo vazio, `return null`, ou `throw`.
2. Consumidor que usa 2 de 15 métodos da interface injetada.
3. Interface que muda por motivos não relacionados entre si.

**Correção:** interfaces por caso de uso, não por entidade. `IOrderReader` e `IOrderWriter` em vez de `IOrderRepository` com 20 membros. Isso também melhora Decorator, porque cada decorator reimplementa menos.

### D — Dependency Inversion

**Heurísticas:**
1. `new` de classe de infraestrutura dentro de regra de negócio (`new SqlConnection`, `new HttpClient`, `new SmtpClient`).
2. Estático não determinístico em regra: `DateTime.Now`, `Guid.NewGuid()`, `Environment.*`, `File.*`.
3. `HttpContext` ou `IHttpContextAccessor` alcançando a regra de negócio. (`HttpContext.Current` é System.Web e não existe em ASP.NET Core; se você encontrar isso, o projeto é .NET Framework e a skill errada está aberta.)
4. `using` de namespace de infraestrutura em arquivo de domínio: `Microsoft.EntityFrameworkCore`, `Microsoft.Data.SqlClient` (o `System.Data.SqlClient` está deprecado, então procure os dois), `System.Net.Http`, `Azure.*`, `StackExchange.Redis`.
5. Cuidado com dois falsos negativos desta checagem: `global using` num arquivo separado esconde o `using` do arquivo que você está lendo, e `PackageReference` injetada por `Directory.Build.props` cria acoplamento que não aparece no `.csproj` do projeto. Confirme no grafo, não só no arquivo.
4. Regra de negócio que só é testável subindo banco ou rede.

**Falso positivo importante:** DIP não exige interface para tudo. Depender de `List<T>`, `string`, `DateTimeOffset` ou de um `record` de domínio é depender de tipo estável, não de detalhe volátil. Criar `IList` própria para "inverter dependência" é overengineering.

---

## Limites numéricos

Não são leis, são gatilhos de investigação. Passar do limite não é defeito automático; é convite para olhar com atenção. Cite o número no achado, porque dá objetividade.

| Métrica | Investigar acima de | Provável problema |
|---|---|---|
| Linhas por método | 30 | Faz mais de uma coisa; extrair método |
| Linhas por classe | 300 | God class; quebrar por responsabilidade |
| Complexidade ciclomática por método | 10 | Muitos caminhos; extrair ou tabelar decisões |
| Profundidade de aninhamento | 3 | Inverter condições, guard clauses, early return |
| Parâmetros por método | 4 | Data clump; agrupar em `record` de parâmetros |
| Dependências no construtor | 5 | SRP; quebrar por caso de uso ou introduzir fachada |
| Métodos públicos por classe | 10 | Interface larga; segregar |
| `if`/`switch` sobre o mesmo conceito espalhados | 3 lugares | Shotgun surgery; centralizar (Strategy, State, tabela) |
| Níveis de herança | 2 | Difícil de depurar; preferir composição |
| Argumentos booleanos em assinatura pública | 1 | Flag argument; quebrar em dois métodos ou usar enum |

---

## Catálogo de code smells

| Smell | Sinal concreto | Correção |
|---|---|---|
| **Long Method** | Método longo com blocos separados por linha em branco e comentários de seção | Extract Method usando os comentários como nomes |
| **Large Class / God Class** | Muitas linhas, muitas dependências, nome genérico (`Manager`, `Helper`, `Utils`, `Processor`) | Quebrar por caso de uso; o nome genérico geralmente esconde 3 classes |
| **Long Parameter List** | 5+ parâmetros, alguns sempre passados juntos | Introduce Parameter Object (`record`) |
| **Data Clump** | O mesmo trio de parâmetros aparecendo em vários métodos | Value object (`readonly record struct`) |
| **Primitive Obsession** | `string cpf`, `decimal valor`, `int diasDeAtraso` circulando sem validação | Value objects com validação no construtor. Elimina uma classe inteira de bug |
| **Feature Envy** | Método que usa mais dados de outro objeto do que os próprios | Mover o método para onde estão os dados |
| **Shotgun Surgery** | Uma mudança de requisito obriga editar 5 arquivos | Centralizar a decisão (Strategy, tabela, State) |
| **Divergent Change** | Um arquivo é editado por motivos totalmente diferentes | SRP: separar |
| **Duplicated Code** | Mesmo bloco em 3 lugares | Na terceira ocorrência, extrair. Com duas, esperar (Regra dos Três) |
| **Speculative Generality** | Interface com uma implementação, parâmetro nunca usado, hook nunca chamado, `virtual` sem override | Remover. É o smell mais comum de overengineering |
| **Temporal Coupling** | Métodos que precisam ser chamados numa ordem, sem o tipo garantir isso (`Configure()` antes de `Execute()`) | Construtor que exige tudo, ou tipos de estado distintos |
| **Boolean Flag Argument** | `Processar(pedido, true)` | Dois métodos com nomes claros, ou enum |
| **Magic String / Number** | `"Ativo"`, `if (status == 3)` | Constantes, enum, ou `FrozenDictionary` |
| **Comentário explicando o quê** | `// incrementa i` ou comentário que traduz o código | Renomear em vez de comentar. Comentário deve dizer *por que* |
| **Dead Code** | Método privado sem chamador, `#region` comentada, parâmetro não lido | Remover. Git guarda o histórico |
| **Nested Ternary** | Ternário dentro de ternário | `switch` de expressão com pattern matching |
| **Exception como fluxo** | `throw` como resultado de negócio **esperado** na camada de aplicação: cliente bloqueado, saldo insuficiente, cupom expirado | Result para o esperado. **Não vale** para guard clause de argumento (`ArgumentNullException.ThrowIfNull`) nem para invariante de domínio no construtor: violação ali é defeito de programação, e lançar é o padrão das Framework Design Guidelines |
| **Anemic Service** | `XService` que só chama `_repo.Save()` | Remover a camada, ou trazer regra para ela |

---

## Anti-padrões

### God Class / God Service

Sinal: `UserService` com 2.000 linhas e 40 dependências. Correção: quebrar **por caso de uso**, não por camada técnica. Quebrar em `UserServiceValidation` + `UserServiceData` só espalha o problema, porque as partes continuam acopladas.

### Anemic Domain Model (com a nuance que importa)

Sinal: entidades que são só `{ get; set; }`, com toda regra nos services.

**Isto só é problema quando existe regra de negócio real para encapsular.** Diga isso explicitamente no review, porque a acusação automática de "modelo anêmico" é uma das crenças mais mal aplicadas em .NET:

- **É problema:** há invariantes (pedido pago não pode ser editado, saldo não pode ficar negativo, status segue máquina de estados) e essas regras estão espalhadas em vários services, permitindo que alguém crie um objeto inválido.
- **Não é problema:** o objeto é DTO, contrato de API, view model, ou entidade de CRUD sem invariantes. Nesses casos, `record` com `{ get; init; }` é o design correto e adicionar comportamento seria cerimônia.

Teste rápido: existe alguma forma de deixar esse objeto num estado inválido pelas propriedades públicas? Se sim, e isso importa para o negócio, há regra faltando na entidade.

Correção quando é problema: setters privados, construtor que garante invariante, e métodos de intenção (`order.Confirm()` em vez de `order.Status = Confirmed`).

### Service Locator

`IServiceProvider` injetado com `GetService<T>()` no meio da regra. O construtor deixa de dizer a verdade, o compilador não ajuda, e a falha aparece em runtime. Aceitável só em fábricas legítimas e na composição da raiz.

### Static Cling

Chamada a estático não determinístico dentro de regra: `DateTime.Now`, `File.ReadAllText`, `ConfigurationManager`. Impede teste determinístico. Correção: `TimeProvider`, `IFileSystem`, `IOptions<T>`.

### Primitive Obsession em identificadores

`Guid` e `int` circulando sem tipo. `Transfer(Guid a, Guid b)` aceita os dois trocados de posição e compila. Correção: strongly-typed IDs com `readonly record struct OrderId(Guid Value)`.

### Exception Swallowing

`catch (Exception) { }` ou `catch { return null; }`. Esconde defeito e transforma bug em comportamento silencioso. Sempre 🔴.

### Copy-Paste Architecture

Camadas criadas por simetria, não por necessidade: `IUserRepository` + `UserRepository` + `IUserService` + `UserService` + `UserController` para um CRUD de 4 campos, onde cada camada só repassa a chamada. Cada nível de repasse é custo sem retorno.

---

## Tratamento de exceções

Verifique sistematicamente. É fonte frequente de 🔴 legítimo.

| Problema | Por que | Correção |
|---|---|---|
| `catch (Exception)` engolindo | Esconde defeito | Capturar o tipo específico, ou não capturar |
| `catch (Exception ex) { throw ex; }` | Reseta o stack trace | `throw;` sozinho |
| Exceção para fluxo esperado | Custo e log poluído | Result |
| `catch` sem log e sem tratamento | Falha invisível | Logar com contexto, ou deixar subir |
| Exceção genérica lançada | `throw new Exception("erro")` não permite tratamento específico | Tipo específico do domínio |
| Mensagem de exceção vazando para o cliente | Expõe interno, risco de segurança | `IExceptionHandler` + `ProblemDetails` |
| `finally` sem `using` para recurso | Risco de leak | `using` / `await using` |
| Tratar todo `OperationCanceledException` como cancelamento | **`TaskCanceledException` herda dela e é o que `HttpClient` e EF lançam em timeout.** Engolir sem distinguir torna timeout de produção invisível | Só é cancelamento com o filtro: `catch (OperationCanceledException) when (ct.IsCancellationRequested)`. Sem o filtro, é falha e loga como erro |

## Validação

Três camadas, com responsabilidades distintas. Confundi-las gera duplicação ou furo.

1. **Contrato (borda):** formato, obrigatoriedade, faixa. FluentValidation, DataAnnotations, ou validação manual no endpoint. Devolve 400/422 com `ProblemDetails`.
2. **Invariante (domínio):** o que nunca pode ser falso para o objeto existir. Vai no construtor ou no método de fábrica da entidade, e lança se violado, porque violação aqui é defeito de programação.
3. **Regra de negócio (aplicação):** depende de estado externo (cliente bloqueado, estoque insuficiente). Vai no handler e devolve `Result`.

Achado comum: validação de contrato repetida no domínio e no endpoint, com mensagens divergentes. Ou o oposto, invariante checada só no endpoint, permitindo criar entidade inválida por outro caminho.

## Nomenclatura

Sinais concretos, não gosto pessoal:

- `Manager`, `Helper`, `Utils`, `Processor`, `Handler` genérico: geralmente esconde que a classe não tem responsabilidade definida.
- Nome que não diz o que devolve: `Get()`, `Process()`, `Execute()` em classe de domínio.
- Abreviação inconsistente: `usr`, `custId`, `qtd` misturados com nomes completos.
- Assíncrono sem sufixo `Async`, ou sufixo `Async` em método sincrônico.
- Booleano sem prefixo de predicado: `Active` em vez de `IsActive`, `HasItems`, `CanShip`.
- Interface nomeada pela implementação (`IEfOrderRepository`), o que denuncia que a abstração não é conceitual.
- Nome que mente: `GetUser` que também cria se não existir. Renomear para `GetOrCreateUser`.
- Português e inglês misturados no mesmo escopo. Aponte apenas como 🟢, e só se for inconsistente dentro do próprio arquivo.

## Testabilidade: as seams

Uma **seam** é um ponto onde você pode trocar comportamento sem editar o código. Sem seam, não há teste unitário. Ao revisar, pergunte: para testar esta regra, o que eu precisaria subir?

| Obstáculo no código | Seam recomendada |
|---|---|
| `DateTime.Now` | `TimeProvider` injetado, `FakeTimeProvider` no teste |
| `Guid.NewGuid()` | Injetar gerador, ou receber o id como parâmetro |
| `new HttpClient()` | `IHttpClientFactory`, ou `HttpMessageHandler` falso |
| `DbContext` concreto | Aceitável: `WebApplicationFactory` + Testcontainers testa melhor que mock |
| `static` manager | Instância com interface, registrada no container |
| `Random` | Injetar `Random` com seed fixa no teste |
| Envio de e-mail/fila dentro da regra | Interface do gateway, verificada por spy |
| `Thread.Sleep` / `Task.Delay` em retry | `TimeProvider` com relógio falso avançando |

Regra de review: se a única forma de testar uma regra de negócio é subindo infraestrutura, isso é um achado 🟠 mesmo que o código esteja "funcionando".
