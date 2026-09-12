# Todas las fuentes de dinero de Balatro

Sacado del código del juego volcado por Lovely (`game.lua`, `card.lua`,
`functions/state_events.lua`), no de memoria. La última columna dice en qué
categoría lo mete Run Tracker.

---

## INGRESOS

### Mecánicas fijas

| Fuente | Cuánto | Categoría |
|---|---|---|
| Small Blind | $3 | `blind` |
| Big Blind | $4 | `blind` |
| Boss normal | $5 | `blind` |
| Boss final (Acorn, Leaf, Vessel, Heart, Bell) | $8 | `blind` |
| Manos sin usar | $1 cada una ($2 con Green Deck) | `hands` |
| Descartes sin usar | solo si el mazo lo da: $1 con Green Deck | `discards` |
| Intereses | $1 por cada $5, tope $25 (o sea máx $5) | `interest` |
| Dinero inicial | $4 ($14 con Yellow Deck) | no se cuenta |

El tope de intereses lo suben **Seed Money** ($50, máx $10) y **Money Tree**
($100, máx $20). El **Green Deck** no da intereses (`no_interest`).

### Jokers que pagan al final de la ronda

Pasan por `Card:calculate_dollar_bonus()`.

| Joker | Cuánto | Categoría |
|---|---|---|
| Golden Joker | $4 | `joker` |
| Cloud 9 | $1 por cada 9 en el mazo | `joker` |
| Rocket | $1, +$2 por cada boss derrotado | `joker` |
| Satellite | $1 por planeta distinto usado en la partida | `joker` |
| Delayed Gratification | $2 por descarte sin usar | `joker` |

### Jokers que pagan al puntuar

Devuelven el dinero dentro de su efecto.

| Joker | Cuánto | Categoría |
|---|---|---|
| Business Card | $2 por carta de figura (1 de cada 2) | `scoring_jokers` |
| Golden Ticket | $4 por carta de oro jugada | `scoring_jokers` |
| Rough Gem | $1 por diamante jugado | `scoring_jokers` |
| Reserved Parking | $1 por figura en mano (1 de cada 2) | `scoring_jokers` |

### Jokers que pagan en el momento

Llaman a `ease_dollars` desde dentro de su cálculo, sin devolverlo en el efecto.

| Joker | Cuándo | Categoría |
|---|---|---|
| Faceless Joker | $5 al descartar 3+ figuras a la vez | `jokers_inplay` |
| Mail-In Rebate | $5 por cada carta del rango elegido descartada | `jokers_inplay` |
| Matador | $8 si la mano activa la habilidad del boss | `jokers_inplay` |
| To Do List | $4 al jugar la mano indicada | `jokers_inplay` |
| Trading Card | $3 al descartar una sola carta | `jokers_inplay` |

### Cartas

| Fuente | Cuánto | Categoría |
|---|---|---|
| Sello dorado | $3 al jugarse la carta | `gold_seals` |
| Carta de oro (mejora) | $3 si la tienes en mano al acabar la ronda | `gold_cards` |
| Lucky Card | $20, 1 de cada 15 | `lucky_cards` |

### Consumibles

| Carta | Cuánto | Categoría |
|---|---|---|
| The Hermit (tarot) | duplica tu dinero, tope $20 | `consumables` |
| Temperance (tarot) | valor de venta de todos tus jokers, tope $50 | `consumables` |
| Immolate (espectral) | $20 destruyendo 5 cartas del mazo | `consumables` |

### Tags

| Tag | Cuánto | Categoría |
|---|---|---|
| Investment Tag | $25 al derrotar el boss | `tag` |
| Handy Tag | $1 por cada mano jugada en la partida | `tag` |
| Garbage Tag | $1 por cada descarte sin usar en la partida | `tag` |
| Economy Tag | duplica tu dinero, tope $40 | `tag` |

### Ventas

Vender un joker o consumible devuelve `floor(coste / 2)`, mínimo $1, más lo que
haya acumulado (el Egg suma +$3 por ronda a su valor de venta). Categoría
`sales`.

---

## GASTOS

| Fuente | Cuánto | Categoría |
|---|---|---|
| Comprar en la tienda | jokers, consumibles, vales y paquetes | `shop` |
| Rerolls | coste creciente dentro de cada tienda | `rerolls` |
| Alquiler (sticker rental) | $3 por ronda y por joker | `rentals` |
| Coste por descarte | solo en algunos desafíos | `discard_cost` |

**Descuentos**: Clearance Sale deja la tienda al 75%, Liquidation al 50%.
**Rerolls más baratos**: Reroll Surplus y Reroll Glut restan $2 cada uno; el
D6 Tag deja la primera tienda con rerolls a $0; Chaos the Clown da un reroll
gratis por tienda.

**Credit Card** no es un gasto: permite que tu dinero baje hasta −$20.

---

## Lo que queda sin clasificar

Todo lo anterior tiene su categoría. El campo `other` solo debería aparecer
con:

- `G.FUNCS.DT_add_money`, la herramienta de depuración del juego ($10).
- Mods que añadan sus propias fuentes.

Si aparece jugando normal, es que hay algo aquí que falta.
