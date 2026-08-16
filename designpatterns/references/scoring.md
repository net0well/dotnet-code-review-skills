# Score: âncoras concretas

Nota sem âncora é ruído. O objetivo destas escalas é que o mesmo código receba aproximadamente a mesma nota em dias diferentes, e que o autor entenda o que falta para subir uma faixa.

## Regras de calibração

1. **Direção da escala:** em todas as dimensões, 10 é o melhor. Em **Complexidade**, 10 significa *simples e fácil de seguir*, e 1 significa *muito complexo*. Deixe isso explícito na linha da nota para não haver ambiguidade.
2. **Uma linha de justificativa por dimensão**, citando o fato que determinou a nota. Nota sem justificativa não é avaliação, é chute.
3. **Combata a inflação.** Não distribua 6 e 7 por padrão. Código realmente bom recebe 9. Para o efeito de um 🔴 na nota, use uma regra só, alinhada com as faixas abaixo: **um 🔴 aberto limita a dimensão afetada a 4; mais de um 🔴, ou risco de perda de dados ou de segurança, limita a 2.** Nenhum outro teto compete com esse.
4. **Combata a severidade excessiva.** Nota baixa exige achado ancorado com linha. Se você não conseguiu apontar problema concreto, a nota é alta.
5. **Não penalize duas vezes o mesmo defeito** em todas as dimensões. Um `switch` grande afeta Design e Complexidade; não precisa derrubar também Clean Code, SOLID, Arquitetura e Manutenibilidade pelo mesmo motivo. Escolha as duas ou três dimensões que ele realmente atinge.
6. **Escopo pequeno restringe o julgamento.** Ao avaliar uma classe isolada, escreva "Arquitetura: não avaliável neste escopo" em vez de inventar nota.
7. **Julgue o código pelo contexto dele.** Um script de migração pontual não deve ser avaliado com o mesmo rigor de um agregado de domínio central. Diga qual contexto você assumiu.

## Faixas gerais

| Faixa | Significado |
|---|---|
| **9 a 10** | Exemplar. Serviria de referência para o time. Nenhum achado relevante nesta dimensão |
| **7 a 8** | Bom e profissional. Achados 🟡 pontuais, nada que exija ação imediata |
| **5 a 6** | Funcional com dívida real. Achados 🟠 que vão doer na próxima mudança |
| **3 a 4** | Problemático. Múltiplos 🟠 ou um 🔴. Precisa de ação planejada |
| **1 a 2** | Crítico. 🔴 abertos, risco de bug ou de perda de dados. Ação imediata |

## Âncoras por dimensão

### Clean Code

Legibilidade, nomes, tamanho, duplicação, comentários, formatação consistente.

- **9 a 10:** nomes revelam intenção sem precisar ler o corpo; métodos curtos e de um nível de abstração; zero duplicação relevante; comentários só onde explicam *por que*.
- **7 a 8:** um ou dois nomes ambíguos, um método um pouco longo, mas o código se lê de cima para baixo.
- **5 a 6:** métodos acima de 30 linhas, nomes genéricos (`Process`, `data`, `Manager`), duplicação em dois ou três pontos, comentários traduzindo o código.
- **3 a 4:** métodos de 80+ linhas, aninhamento profundo, magic strings, código morto, `#region` escondendo tamanho.
- **1 a 2:** ilegível sem executar mentalmente; nomes enganosos; duplicação massiva.

### SOLID

- **9 a 10:** responsabilidades claras; extensão por acréscimo; interfaces enxutas e honestas; dependências invertidas onde importa, sem abstração inútil.
- **7 a 8:** uma violação localizada e de baixo impacto.
- **5 a 6:** SRP ou OCP violado de forma visível (`switch` que cresce, classe com dois motivos de mudança), mas contornável.
- **3 a 4:** múltiplas violações, incluindo dependência concreta em regra de negócio que impede teste.
- **1 a 2:** nenhuma separação; regra, dados e infraestrutura no mesmo lugar; herança quebrando contrato.

Nota importante: **abstração excessiva também derruba SOLID**. Cinco interfaces de uma implementação cada não é 10, é violação do espírito do princípio (YAGNI e complexidade sem retorno). Penalize.

### Design

Escolha das abstrações, uso correto de padrões, modelagem dos tipos, coesão.

- **9 a 10:** abstrações no ponto exato da variação; padrões presentes usados corretamente e nomeados; tipos que impedem estado inválido.
- **7 a 8:** design sólido com uma oportunidade clara não aproveitada.
- **5 a 6:** design procedural onde havia ganho claro em isolar variação, ou padrão aplicado pela metade.
- **3 a 4:** padrão usado incorretamente (Repository vazando `IQueryable`, Singleton com estado, Strategy com `if` no contexto), ou overengineering pesado.
- **1 a 2:** design que atrapalha ativamente, com indireção que esconde o fluxo sem entregar flexibilidade.

### Arquitetura

Escreva "não avaliável neste escopo" quando for uma classe isolada.

- **9 a 10:** dependências apontando para o centro; domínio limpo de infraestrutura; fronteiras claras; transação com limite definido.
- **7 a 8:** estrutura correta com um vazamento pontual.
- **5 a 6:** camadas existem mas são atravessadas (controller usando `DbContext`), ou camadas de puro repasse.
- **3 a 4:** domínio acoplado ao ORM, regra de negócio no controller, God Service central.
- **1 a 2:** dependências circulares, tudo referenciando tudo, nenhuma fronteira.

### Manutenibilidade

Custo de fazer a próxima mudança.

- **9 a 10:** adicionar um caso novo é criar um arquivo; o impacto de qualquer mudança é local e previsível.
- **7 a 8:** mudanças exigem tocar dois pontos relacionados.
- **5 a 6:** mudança típica exige editar código existente em três ou mais lugares (shotgun surgery).
- **3 a 4:** medo justificado de mexer; efeito colateral difícil de prever.
- **1 a 2:** qualquer alteração é risco alto sem cobertura.

### Testabilidade

- **9 a 10:** toda regra testável por construtor, sem infraestrutura; relógio, aleatoriedade e I/O injetados.
- **7 a 8:** maior parte testável; um ponto exige teste de integração.
- **5 a 6:** regra misturada com acesso a dados; teste exige subir banco ou `WebApplicationFactory` para verificar cálculo.
- **3 a 4:** estáticos não determinísticos (`DateTime.Now`, `File`) dentro da regra; sem seam.
- **1 a 2:** impossível testar sem ambiente completo; estado global compartilhado.

### Complexidade (10 = simples)

- **9 a 10:** fluxo linear, poucos caminhos, aninhamento raso, sem estado escondido.
- **7 a 8:** complexidade proporcional ao problema.
- **5 a 6:** métodos com muitos caminhos, condicionais aninhadas, complexidade acidental identificável.
- **3 a 4:** complexidade ciclomática alta, muitos booleanos de controle, fluxo difícil de seguir.
- **1 a 2:** exige diagrama para entender um método; ou indireção artificial (overengineering) que multiplica arquivos sem reduzir complexidade real.

Este último ponto merece atenção: **overengineering derruba a nota de Complexidade**, porque sete camadas entre o endpoint e a linha que faz o trabalho tornam o sistema mais difícil de seguir, mesmo que cada classe isolada seja simples.

## Formato de apresentação

```
## 📊 Score

| Dimensão | Nota | Por quê |
|---|---|---|
| Clean Code | 7/10 | Nomes claros, mas `ProcessarPedido` tem 62 linhas e três níveis de aninhamento |
| SOLID | 5/10 | OCP violado: o `switch` da linha 34 cresce a cada modalidade nova |
| Design | 6/10 | Procedural onde Strategy resolveria; nenhum padrão mal aplicado |
| Arquitetura | não avaliável neste escopo | Apenas uma classe recebida |
| Manutenibilidade | 5/10 | Modalidade nova exige editar 2 métodos e 1 enum |
| Testabilidade | 4/10 | `DateTime.Now` na linha 51 e `new SmtpClient()` na 88 impedem teste unitário |
| Complexidade | 6/10 | (10 = simples) Complexidade ciclomática ~12 em `ProcessarPedido` |
```

Depois da tabela, três blocos curtos:

**Principais problemas:** de 3 a 5 itens, o mais grave primeiro.

**Melhorias recomendadas:** em ordem de prioridade, com esforço (baixo/médio/alto).

**Patterns recomendados:** somente os que passaram no teste do aluguel. Se nenhum passou, escreva isso com clareza, porque é resultado legítimo e frequente.

**Patterns que NÃO usaria:** os candidatos plausíveis que você descartou, com o motivo em uma linha cada.
