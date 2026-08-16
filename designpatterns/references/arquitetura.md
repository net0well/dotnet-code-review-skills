# Review de arquitetura

Leia quando o escopo passar de um arquivo. Arquitetura é sobre **direção de dependências** e **onde as decisões moram**, não sobre quantidade de camadas.

## Índice

- [Como conduzir o review arquitetural](#como-conduzir-o-review-arquitetural)
- [Detecção mecânica de violações](#detecção-mecânica-de-violações)
- [O que verificar em cada camada](#o-que-verificar-em-cada-camada)
- [Escolha de arquitetura](#escolha-de-arquitetura)
- [Smells arquiteturais](#smells-arquiteturais)
- [Refatoração arquitetural incremental](#refatoração-arquitetural-incremental)

---

## Como conduzir o review arquitetural

Ordem que dá mais retorno com menos leitura:

1. **Leia os `.csproj` primeiro.** As referências entre projetos revelam a arquitetura real, que muitas vezes contradiz a arquitetura pretendida pelos nomes das pastas.
2. **Desenhe o grafo de dependências mentalmente.** Procure ciclos e setas apontando para fora do que deveria ser o centro.
3. **Verifique os `using` do domínio.** É a checagem de maior retorno do review inteiro: um `using Microsoft.EntityFrameworkCore` num arquivo de domínio prova vazamento de infraestrutura.
4. **Abra um controller ou endpoint.** Se ele tem regra de negócio, a arquitetura não está sendo respeitada, independente de quantos projetos existam.
5. **Abra a maior classe.** God class é o sintoma arquitetural mais comum.
6. **Verifique onde a transação começa e termina.** Fronteira de transação difusa é fonte de bug de consistência.
7. **Só então comente estrutura de pastas**, que é o aspecto menos importante e o que mais atrai comentário cosmético.

## Detecção mecânica de violações

Sinais verificáveis, não interpretação:

| Verificação | Violação que revela |
|---|---|
| `Domain.csproj` referenciando `Infrastructure.csproj` | Inversão de dependência quebrada na raiz |
| `using Microsoft.EntityFrameworkCore` em arquivo de domínio | Domínio acoplado ao ORM |
| Atributo de mapeamento (`[Table]`, `[Column]`) na entidade de domínio | Persistência vazando para o modelo. Use Fluent API na Infrastructure |
| `using System.Net.Http` em Application ou Domain | Detalhe de transporte vazando |
| `using Microsoft.AspNetCore.*` fora da camada de API | Web vazando para dentro |
| `DbContext` referenciado em controller | Pula a camada de aplicação |
| Entidade do EF usada como contrato de resposta HTTP | Acopla API ao esquema do banco; risco de vazar campo |
| Ciclo de referência entre projetos | Fronteira mal definida (o compilador impede entre projetos, mas ciclos entre pastas/módulos passam) |
| Interface e implementação no mesmo projeto de infraestrutura, consumidas pelo domínio | A abstração está do lado errado. Interface pertence a quem consome |
| Dois módulos acessando as tabelas um do outro | Fronteira de módulo furada |
| `internal` ausente em tudo | Toda classe pública é superfície de acoplamento |

## O que verificar em cada camada

### Domain

- Contém entidades, value objects, eventos de domínio, e as regras que são verdade independentemente de tecnologia.
- **Não deve** ter `using` de ORM, HTTP, web, serialização específica, nem de biblioteca de terceiro de infraestrutura.
- Invariantes garantidas no construtor e em métodos de intenção. Setters públicos em entidade com invariante são achado.
- Se este projeto está vazio ou só tem classes com `{ get; set; }`, e existe regra de negócio real no sistema, aponte o modelo anêmico. Se não existe regra real, diga que a camada é cerimônia e pode ser removida.

### Application

- Casos de uso, orquestração, contratos das dependências externas (as interfaces vivem aqui, as implementações não).
- **Não deve** conter SQL, chamada HTTP direta, nem regra que pertence à entidade.
- Verifique se o caso de uso é uma fachada fina orquestrando, ou se virou um God Service de 800 linhas.
- Fronteira de transação normalmente pertence aqui.

### Infrastructure

- Implementações: EF Core, clientes HTTP, fila, e-mail, storage, cache.
- Depende de Application e Domain, nunca o contrário.
- Cada integração externa deve estar atrás de uma interface definida na Application (anti-corruption layer). Se o DTO do fornecedor circula pelo sistema, aponte.

### API / apresentação

- Só tradução: HTTP para caso de uso e resultado para HTTP.
- Verifique: regra de negócio no endpoint, `DbContext` injetado no controller, entidade devolvida como resposta, ausência de `CancellationToken`, ausência de autorização.

## Escolha de arquitetura

Não recomende trocar de arquitetura sem motivo forte. Reescrita arquitetural é a mudança mais cara e mais arriscada que existe.

| Arquitetura | Cabe quando | Não cabe quando |
|---|---|---|
| **Um projeto só** | CRUD, ferramenta interna, protótipo, time de 1 a 2 pessoas | Domínio complexo com invariantes ricas, ou vários times |
| **Vertical Slice** | Muitas features independentes, time pequeno ou médio, CRUD com alguma regra. Cada slice tem endpoint, handler, validação e acesso a dados juntos | Regras muito compartilhadas entre slices, gerando duplicação real |
| **Clean Architecture** | Domínio com complexidade real, vida longa, mais de um consumidor, exigência de testabilidade forte | CRUD. Aqui ela cobra 4 projetos e entrega pouco |
| **DDD tático + Clean** | Domínio central do negócio, invariantes complexas, linguagem própria, especialista de domínio disponível | Domínio de suporte ou genérico. Não faça DDD em cadastro auxiliar |
| **Monolito modular** | Vários subdomínios, mais de um time, quer fronteiras sem custo de rede | Sistema pequeno, onde módulo vira só pasta com nome bonito |
| **Microsserviços** | Times independentes, necessidade real de escala e deploy separados, domínio já estabilizado | Time pequeno, domínio instável. Custo operacional supera o ganho |

Observação para o review: é perfeitamente válido um sistema misturar. Vertical Slice para a maior parte das features e Clean com DDD no módulo que concentra a complexidade é uma escolha madura, não inconsistência.

## Smells arquiteturais

| Smell | Sinal | Correção |
|---|---|---|
| **Anemic layering** | Cada camada só repassa a chamada para a próxima | Remover camadas de repasse |
| **Business logic no controller** | Cálculo, condicional de negócio, orquestração no endpoint | Mover para caso de uso |
| **Big Ball of Mud** | Todo projeto referencia todo projeto | Definir o centro e inverter as setas de fora para dentro |
| **Domain vazando infraestrutura** | `using` de ORM/HTTP no domínio | Interface na Application, implementação na Infrastructure |
| **God Service** | Um serviço com 40 dependências | Quebrar por caso de uso |
| **Shared kernel inflado** | Projeto `Common`/`Shared` que tudo referencia e que contém regra de negócio | Manter só primitivos e contratos estáveis; regra volta para o módulo dono |
| **Distributed monolith** | Microsserviços que só funcionam se todos estiverem no ar, e um deploy exige coordenação | Voltar para monolito modular, ou desacoplar de verdade com mensageria |
| **Módulo com fronteira furada** | Módulo A lendo tabela do módulo B | Comunicação por interface pública do módulo, ou por evento |
| **Transação difusa** | `SaveChanges` chamado em vários pontos de um mesmo fluxo | Um commit por unidade de trabalho, na fronteira do caso de uso |
| **Camada anticorrupção ausente** | DTO de fornecedor circulando no domínio | Adapter na borda traduzindo para o vocabulário interno |
| **Configuração espalhada** | `IConfiguration` lido em vários pontos internos | Options tipadas injetadas |

## Refatoração arquitetural incremental

Nunca proponha reescrita completa. Proponha fases, cada uma entregando valor e podendo parar sem deixar o sistema pior. Modelo de proposta:

**Fase 1, criar a seam sem mudar comportamento.** Extrair interface do ponto de acoplamento mais doloroso, registrar no container, e continuar usando a implementação atual. Nenhum comportamento muda, e a partir daqui já é possível testar.

**Fase 2, isolar o caso de uso mais crítico.** Escolher um fluxo (o que quebra mais, ou o que muda mais), mover a regra para uma classe de caso de uso, cobrir com teste, e deixar o resto como está.

**Fase 3, inverter a dependência mais grave.** Mover a interface para o lado de quem consome e ajustar as referências de projeto.

**Fase 4, replicar o padrão nos fluxos restantes**, um por vez, à medida que forem tocados por demanda de negócio. Não abra frente de refatoração em código que ninguém está mexendo.

Duas regras que valem dizer explicitamente ao autor:

- Priorize por **risco vezes frequência de mudança**. Código feio que ninguém toca há dois anos e funciona não é prioridade, é estabilidade.
- Refatoração sem teste é mudança de comportamento com esperança. Se não há teste no caminho, a fase 1 de qualquer plano é criar a seam e escrever o teste de caracterização.
