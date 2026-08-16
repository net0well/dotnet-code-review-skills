# Score no legado: âncoras ajustadas

Aplicar a régua do .NET moderno a código de 2013 produz uma fileira de notas 3 e nenhuma informação útil. Um score assim é desmotivador e, pior, não orienta ação, porque não distingue o que é defeito do que é apenas a plataforma da época.

## Princípio de calibração

> Avalie o código **contra o que era possível fazer bem na plataforma dele**, e separe a nota da qualidade do código da nota do risco que ele carrega hoje.

Uma classe escrita em C# 5, sem `record`, sem interpolação e sem async, pode ser um excelente código. Ausência de recurso moderno não é defeito. Deadlock, SQL injection e exceção engolida são defeitos, e esses pesam.

Regras práticas:

1. **Nunca penalize por ausência de recurso indisponível.** Não desconte por não usar `TimeProvider`, `record` ou padrão primário se o alvo não suporta.
2. **Penalize datação apenas quando há custo ativo.** `DataTable` num fluxo que ninguém toca não desconta nada. `DataTable` atravessando cinco camadas de um fluxo que muda toda semana desconta.
3. **Defeito de correção pesa cheio.** Deadlock, race condition, SQL injection, vazamento de conexão e exceção engolida derrubam a nota do mesmo jeito que derrubariam num projeto novo, porque causam prejuízo hoje.
4. **Ausência de teste é achado, não sentença.** Derruba Testabilidade, mas não deve derrubar Clean Code e Design junto pelo mesmo motivo.
5. **Declare o contexto assumido** em uma linha antes da tabela, para o autor saber contra o que foi medido.
6. **Direção da escala:** 10 é sempre o melhor. Em Complexidade, 10 significa simples.

## Duas notas que valem mais que as sete

Além das sete dimensões pedidas, acrescente estas duas no legado. Elas são as que realmente orientam decisão, porque respondem "devo mexer nisso?".

**Risco operacional (1 a 10, onde 10 é seguro).** Qual a chance de este código causar incidente como está? Deadlock sob carga, vazamento de conexão, SQL injection e perda silenciosa de trabalho derrubam esta nota mesmo que o design seja elegante.

**Custo de mudança (1 a 10, onde 10 é barato).** Se o negócio pedir uma alteração aqui amanhã, quanto custa e qual o risco de regressão? Sem teste e com regra espalhada, esta nota é baixa mesmo que o código seja legível.

A combinação das duas dá a priorização real: **risco baixo e custo de mudança alto** significa "não mexa agora, está estável"; **risco alto** significa "aja independentemente da elegância".

## Âncoras por dimensão

### Clean Code

- **9 a 10:** nomes claros, métodos curtos, sem duplicação relevante, considerando o estilo da época. Um `if/else` explícito em C# 5 onde hoje se usaria pattern matching continua sendo 10.
- **7 a 8:** um ou dois métodos longos, alguns nomes genéricos.
- **5 a 6:** métodos acima de 60 linhas, `#region` escondendo tamanho, duplicação em vários pontos, magic strings espalhadas.
- **3 a 4:** métodos de 200+ linhas, aninhamento de 5 níveis, código morto e comentado em quantidade.
- **1 a 2:** arquivo de milhares de linhas sem estrutura reconhecível.

### SOLID

- **9 a 10:** responsabilidades separadas e dependências recebidas por construtor, o que é perfeitamente possível em C# 5.
- **7 a 8:** uma violação localizada.
- **5 a 6:** `switch` que cresce, classe com dois motivos de mudança, algum `new` de infraestrutura em regra.
- **3 a 4:** regra, dados e apresentação misturados; dependências todas concretas.
- **1 a 2:** nenhuma separação, e estáticos por toda parte.

### Design

- **9 a 10:** abstrações no ponto de variação, padrões corretos, tipos que impedem estado inválido.
- **7 a 8:** procedural mas coerente e previsível.
- **5 a 6:** oportunidade clara de isolar variação não aproveitada em código que muda com frequência.
- **3 a 4:** padrão mal aplicado (Generic Repository com `GetAll`, Singleton com estado mutável, Strategy com `if` no contexto).
- **1 a 2:** design que atrapalha, com indireção que esconde o fluxo sem entregar nada.

### Arquitetura

- **9 a 10:** camadas com responsabilidade real e regra de negócio isolável em `netstandard`.
- **7 a 8:** estrutura correta com vazamentos pontuais de `System.Web`.
- **5 a 6:** regra de negócio no code-behind ou no controller, mas contida.
- **3 a 4:** `HttpContext.Current` e `ConfigurationManager` espalhados pela regra; acesso a dados em qualquer lugar.
- **1 a 2:** nenhuma fronteira; SQL na página, regra no `Global.asax`, estático global compartilhado.

Nota útil de acrescentar aqui: diga se a regra de negócio conseguiria ser extraída para `netstandard2.0` hoje. Essa é a medida mais concreta de saúde arquitetural num legado, porque é exatamente o que uma migração futura vai exigir.

### Manutenibilidade

- **9 a 10:** caso novo é arquivo novo; impacto local.
- **7 a 8:** mudanças exigem tocar dois pontos relacionados.
- **5 a 6:** shotgun surgery em três ou mais lugares.
- **3 a 4:** medo justificado de mexer, com efeito colateral imprevisível.
- **1 a 2:** qualquer alteração é aposta.

### Testabilidade

Aqui a régua é a mais dura, porque é o que mais bloqueia evolução, e é o que tem correção mais barata via seam.

- **9 a 10:** dependências por construtor, relógio e I/O abstraídos, e existe projeto de teste cobrindo o caminho.
- **7 a 8:** testável por construtor, mesmo sem teste escrito ainda.
- **5 a 6:** exige Extract and Override para testar, mas há caminho claro.
- **3 a 4:** `DateTime.Now`, `HttpContext.Current`, `new SqlConnection` e estáticos dentro da regra. Sem seam.
- **1 a 2:** só testável subindo IIS e banco; estado global compartilhado entre execuções.

### Complexidade (10 = simples)

- **9 a 10:** fluxo linear, poucos caminhos.
- **7 a 8:** complexidade proporcional ao problema.
- **5 a 6:** muitos caminhos e condicionais aninhadas.
- **3 a 4:** complexidade ciclomática alta, muitos booleanos de controle, `goto` ou flags de fluxo.
- **1 a 2:** exige diagrama para entender um método.

## Formato de apresentação

```
## 📊 Score

Avaliado como aplicação ASP.NET MVC 5 em net472, C# 7.3, sem projeto de teste,
em produção. Notas medidas contra o que é possível fazer bem nessa plataforma.

| Dimensão | Nota | Por quê |
|---|---|---|
| Clean Code | 6/10 | `ProcessarLote` tem 140 linhas e 4 níveis de aninhamento |
| SOLID | 5/10 | `new SqlConnection` na linha 88 dentro da regra de cálculo |
| Design | 6/10 | Procedural coerente; nenhum padrão mal aplicado |
| Arquitetura | 4/10 | `HttpContext.Current` na linha 34 impede extrair a regra para netstandard |
| Manutenibilidade | 5/10 | Modalidade nova exige editar 3 métodos |
| Testabilidade | 3/10 | `DateTime.Now` (l. 51) e conexão criada dentro do método; sem seam |
| Complexidade | 5/10 | (10 = simples) Ciclomática ~15 em `ProcessarLote` |
| **Risco operacional** | **2/10** | **`.Result` na linha 62 sob ASP.NET: deadlock provável sob carga** |
| **Custo de mudança** | **4/10** | Sem teste, e a regra está acoplada ao contexto web |
```

Depois da tabela:

**Principais problemas:** 3 a 5 itens, o de maior risco primeiro, não o de pior design.

**Melhorias recomendadas:** em ordem de risco vezes frequência de mudança, com esforço e **risco de regressão** de cada uma. O risco da própria correção é informação que o autor precisa para decidir.

**Patterns recomendados:** só os que reduzem risco ou destravam demanda concreta.

**Patterns que NÃO usaria:** com o custo de risco explicado, não apenas o de complexidade.

**Datação aceitável:** o que é antigo e está adequado. Isso evita que o autor gaste esforço no lugar errado, e é uma das partes mais úteis do relatório.
