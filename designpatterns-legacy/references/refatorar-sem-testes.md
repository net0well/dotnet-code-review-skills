# Refatorar sem testes: seams e passos seguros

A maior parte do código legado não tem teste, e o motivo é circular: não tem teste porque não é testável, e não é testável porque as dependências estão cravadas dentro das classes. Quebrar esse ciclo é a habilidade central do trabalho com legado.

A sequência que funciona é sempre a mesma: **encontrar uma seam, escrever teste de caracterização em torno dela, e só então mudar o código.**

## O que é uma seam

Uma seam é um ponto onde você consegue alterar o comportamento **sem editar** o código naquele ponto. Sem seam, não existe teste unitário, porque não há como substituir o banco, o relógio ou a chamada de rede.

Tipos de seam disponíveis em C#:

| Tipo | Como se cria | Custo |
|---|---|---|
| **Construtor** | Receber a dependência por parâmetro em vez de dar `new` | Baixo, é o objetivo final |
| **Método virtual** | Tornar o método `virtual` e sobrescrever numa subclasse de teste | Muito baixo, ideal como primeiro passo |
| **Interface** | Extrair interface e injetar | Médio, exige tocar os consumidores |
| **Delegate / `Func<>`** | Receber um `Func<>` em vez de chamar direto | Baixo, útil quando a interface seria exagero |
| **Parâmetro opcional** | Adicionar parâmetro com valor padrão para não quebrar chamadores | Muito baixo, ótimo em biblioteca compartilhada |

A seam de menor risco em legado quase sempre é o **método virtual**, porque não muda assinatura nem chamador algum.

## Teste de caracterização

Um teste de caracterização **documenta o que o código faz hoje**, não o que deveria fazer. Essa distinção é essencial e vale explicar ao autor.

Procedimento:

1. Escreva um teste chamando o código com entrada realista.
2. Deixe a asserção com um valor obviamente errado, por exemplo `Assert.AreEqual(0, resultado)`.
3. Rode. A falha revela o valor real.
4. Coloque o valor real na asserção.
5. Repita para os casos de borda que você conseguir alcançar.

Agora você tem uma rede. Se a refatoração mudar qualquer um desses valores, você saberá imediatamente.

Ponto delicado: se o teste revelar que o código faz algo aparentemente errado (arredondamento estranho, fuso invertido, caso especial esquisito), **registre o comportamento atual e marque como pergunta ao negócio**. Pode ser um bug de dez anos que virou regra de fato, com relatórios e integrações dependendo dele. Corrigir é decisão de produto, não do refactor.

## Técnicas de mudança segura

Nomenclatura consagrada por Michael Feathers em *Working Effectively with Legacy Code*. Todas compartilham a ideia de **acrescentar em volta em vez de reescrever dentro**.

### Sprout Method

Você precisa adicionar comportamento a um método enorme e intestável. Em vez de escrever a lógica nova lá dentro, coloque num método novo, isolado e testável, e chame-o de uma linha.

```csharp
// ANTES: método de 300 linhas onde você precisaria enfiar a regra nova

// DEPOIS: a regra nova nasce testável, e o método antigo ganha uma linha
public void ProcessarPedido(Pedido pedido)
{
    // ... as 300 linhas existentes, intocadas ...

    AplicarDescontoFidelidade(pedido);   // <- a única linha adicionada
}

// novo, pequeno, sem dependência, testável isoladamente
internal static void AplicarDescontoFidelidade(Pedido pedido)
{
    if (pedido.Cliente.AnosDeRelacionamento >= 5)
        pedido.Desconto = pedido.Total * 0.05m;
}
```

Ganho: a lógica nova é 100% coberta, e o risco de regressão fica limitado a uma linha.

### Sprout Class

Mesma ideia, quando o comportamento novo é grande ou tem dependências próprias. Crie uma classe nova, testável, e instancie-a do método legado.

### Wrap Method

Você precisa executar algo **sempre que** o método existente for chamado (log, auditoria, métrica). Renomeie o original e crie um novo com o nome antigo que chama os dois.

```csharp
// ANTES
public void Salvar(Pedido pedido) { /* corpo original */ }

// DEPOIS
public void Salvar(Pedido pedido)
{
    SalvarOriginal(pedido);
    RegistrarAuditoria(pedido);     // comportamento novo
}

private void SalvarOriginal(Pedido pedido) { /* corpo original, intocado */ }
private void RegistrarAuditoria(Pedido pedido) { /* novo, testável */ }
```

Nenhum chamador muda. É Decorator feito por dentro, sem container de DI.

### Extract and Override Call

A técnica de maior retorno para tornar código legado testável **sem mudar assinatura**. Isole a chamada problemática num método `virtual` protegido, e sobrescreva numa subclasse de teste.

```csharp
public class RelatorioService
{
    public decimal CalcularJuros(Contrato contrato)
    {
        var hoje = ObterDataAtual();       // era DateTime.Now direto
        var dias = (hoje - contrato.Vencimento).Days;
        return dias > 0 ? contrato.Valor * 0.001m * dias : 0m;
    }

    // seam: nenhum chamador externo muda
    protected virtual DateTime ObterDataAtual()
    {
        return DateTime.Now;
    }
}

// no teste
public class RelatorioServiceTestavel : RelatorioService
{
    private readonly DateTime _fixa;
    public RelatorioServiceTestavel(DateTime fixa) { _fixa = fixa; }
    protected override DateTime ObterDataAtual() { return _fixa; }
}
```

Isso permite testar a regra hoje, com risco praticamente zero. Depois, quando houver confiança e cobertura, o passo seguinte é trocar o método virtual por um `IClock` injetado. **Dois passos pequenos são mais seguros que um grande.**

### Parameterize Constructor

A classe dá `new` numa dependência no construtor. Adicione uma sobrecarga que aceita a dependência, e faça o construtor antigo delegar para ela com a implementação real. Nenhum chamador quebra.

```csharp
public class NotaFiscalService
{
    private readonly ISefazGateway _gateway;

    // construtor antigo continua funcionando
    public NotaFiscalService() : this(new SefazGateway()) { }

    // construtor novo: a seam
    public NotaFiscalService(ISefazGateway gateway)
    {
        _gateway = gateway;
    }
}
```

### Break Out Method Object

Método gigante com muitas variáveis locais. Crie uma classe cujos campos são essas variáveis e cujo método `Executar()` contém o corpo. Agora dá para quebrar em métodos privados que compartilham estado por campo, e testar cada parte.

## Ordem recomendada de um refactor de legado

Apresente sempre nesta forma faseada, porque cada fase pode parar sem deixar o sistema pior:

**Fase 1, seam sem mudança de comportamento.** Extract and Override, ou construtor parametrizado. Compila igual, roda igual, nenhum chamador afetado. Risco praticamente nulo.

**Fase 2, teste de caracterização.** Cobrir o comportamento atual usando a seam da fase 1, incluindo os casos de borda alcançáveis.

**Fase 3, a mudança que você realmente queria.** Agora com rede.

**Fase 4, limpeza opcional.** Trocar o método virtual por injeção de interface, remover a subclasse de teste, registrar no container. Só se houver retorno claro.

Diga explicitamente ao autor que **parar depois da fase 2 já é lucro**: o sistema ficou testável e documentado, sem nenhum risco assumido.

## Erros comuns em refactor de legado

| Erro | Por que dá ruim |
|---|---|
| Refatorar e mudar comportamento no mesmo commit | Se algo quebra, você não sabe qual das duas coisas causou |
| Começar pela classe mais feia | A mais feia costuma ser a mais arriscada e a que menos muda. Comece pela que o negócio está pedindo para mudar |
| Extrair interface de tudo antes de ter teste | Muita movimentação, nenhuma rede, e a interface provavelmente estará errada |
| Reescrever o método inteiro "aproveitando que estou aqui" | Diff grande é irrevisável, e o conhecimento embutido nos casos de borda se perde |
| Renomear em massa junto com refactor | Polui o diff e esconde a mudança real |
| Corrigir o comportamento estranho sem perguntar | Pode ser requisito não documentado do qual alguém depende |
| Introduzir container de DI em toda a aplicação de uma vez | Falha em runtime, longe do ponto de mudança, e difícil de reverter |
| Confiar que "compilou, então está certo" | Reflection, binding de view, serialização e injeção por string não são verificados pelo compilador |

## O que verificar antes de propor qualquer mudança

- Existe `Reflection`, binding por string, serialização, ou injeção por nome apontando para o membro que você quer renomear? O compilador não vai te avisar.
- O método é público em biblioteca consumida por outra solução?
- Há `partial class` com a outra metade em arquivo gerado?
- Existe procedure ou trigger no banco que replica essa regra?
- O comportamento depende de cultura, fuso, ou de configuração de servidor?
