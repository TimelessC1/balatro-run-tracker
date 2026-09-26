-- ============================================================
--  Run Tracker for Balatro
--  Registra seed + resultado al terminar cada partida y lo
--  envia por HTTPS a un endpoint propio.
--  Requiere: Lovely Injector + Steamodded 1.x
--
--  Copyright (C) 2026 TimelessC1
--
--  This program is free software: you can redistribute it and/or
--  modify it under the terms of the GNU General Public License as
--  published by the Free Software Foundation, either version 3 of
--  the License, or (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program. If not, see <https://www.gnu.org/licenses/>.
-- ============================================================

local MOD = SMODS.current_mod
local PENDING_FILE = "run_tracker_pending.jsonl"
local LOG_FILE     = "run_tracker_log.jsonl"
local TXT_FILE     = "run_tracker_results.txt"

--------------------------------------------------------------
-- Configuracion
--------------------------------------------------------------

-- Valores por defecto. settings.lua los pisa, pero el mod tiene que funcionar
-- aunque ese fichero no exista: un mod publico no puede depender de que el
-- que lo instala edite nada.
local CFG = {
    enabled = true,
    -- Servidor publico. Es una URL, no un secreto.
    endpoint = "https://balatro-run-tracker.timelessc.workers.dev/run",
    -- El servidor publico no pide token. Solo hace falta si montas el tuyo
    -- propio con INGEST_TOKEN configurado.
    token = "",
    player_name = "",
    always_log_local = true,
    write_txt = true,
    -- Desactivado a proposito: por defecto no se manda el SteamID de nadie.
    -- Para distinguir jugadores ya esta user_code, que es un hash.
    send_steam_id = false,
    include_jokers = true,
    track_joker_values = true,
    only_vanilla_jokers = true,
    -- Las partidas con mazos de otros mods se guardan en local pero no se suben.
    only_vanilla_decks = true,
    -- Contar de donde sale y a donde va el dinero de cada partida.
    track_money = true,
    -- Apuntar cada joker que pasa por tu fila y cuantas rondas se queda.
    track_joker_history = true,
    -- Nivel y veces jugada de cada mano de poker. Es una sola lectura de
    -- G.GAME.hands al cerrar la partida: el juego ya lleva la cuenta, aqui
    -- no se cuenta nada durante la run.
    track_hands = true,
    retry_pending_on_boot = true,
    debug = false,
}

local SETTINGS_LOADED = false
do
    local ok, chunk = pcall(SMODS.load_file, "settings.lua", MOD and MOD.id)
    if ok and type(chunk) == "function" then
        local ok2, user = pcall(chunk)
        if ok2 and type(user) == "table" then
            for k, v in pairs(user) do CFG[k] = v end
            SETTINGS_LOADED = true
        end
    end
end

-- Un endpoint sin configurar no debe intentar enviarse ni llenar la cola de
-- pendientes: se trata como modo local y se avisa.
local ENDPOINT_WARNING = nil
if type(CFG.endpoint) ~= "string" then
    CFG.endpoint = ""
-- Cualquier resto de la plantilla (TU-CUENTA, TU-WORKER, REEMPLAZA...) cuenta
-- como endpoint sin configurar: en mayusculas y con guion no aparece en una
-- URL de verdad.
elseif CFG.endpoint:find("TU%-") or CFG.endpoint:find("REEMPLAZA")
       or CFG.endpoint:find("EJEMPLO") or CFG.endpoint:find("XXXX") then
    ENDPOINT_WARNING = "endpoint is still the example one; working in local mode"
    CFG.endpoint = ""
elseif CFG.endpoint ~= "" and not CFG.endpoint:match("^https?://") then
    ENDPOINT_WARNING = "endpoint does not start with http:// or https://; working in local mode"
    CFG.endpoint = ""
end

local function log(msg, level)
    if level == "debug" and not CFG.debug then return end
    pcall(sendInfoMessage, "[RunTracker] " .. tostring(msg), "RunTracker")
end

--------------------------------------------------------------
-- Codificador JSON minimo (sin dependencias)
--------------------------------------------------------------

local ARRAY_MT = { __jsonarray = true }
local function array(t) return setmetatable(t or {}, ARRAY_MT) end

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
    ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function esc_str(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', c:byte())
    end))
end

--- Un numero, en texto, para el JSON.
---
--- Los enteros van con "%.0f" y no con "%d" a proposito. El "%d" de LuaJIT
--- pasa el double por un entero de 32 bits, asi que cualquier puntuacion por
--- encima de 4 294 967 296 daba la vuelta: una ronda de 17 008 070 538 681
--- llego a la web como 46 521, que es justo ese numero modulo 2^32. El "%.0f"
--- formatea el double tal cual y aguanta hasta 2^53 sin perder un digito.
local function enc_number(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n % 1 == 0 and math.abs(n) < 9007199254740992 then
        return string.format("%.0f", n)
    end
    return string.format("%.14g", n)
end

local encode
encode = function(v, depth)
    depth = (depth or 0) + 1
    if depth > 12 then return "null" end
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return enc_number(v)
    elseif t == "string" then
        return '"' .. esc_str(v) .. '"'
    elseif t == "table" then
        local mt = getmetatable(v)
        local is_array = (mt and mt.__jsonarray) and true or false
        if not is_array and #v > 0 then
            is_array = true
            for k in pairs(v) do
                if type(k) ~= "number" then is_array = false break end
            end
        end
        if is_array then
            local out = {}
            for i = 1, #v do out[#out + 1] = encode(v[i], depth) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local out = {}
        for k, val in pairs(v) do
            if type(k) == "string" and val ~= nil then
                out[#out + 1] = '"' .. esc_str(k) .. '":' .. encode(val, depth)
            end
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

--------------------------------------------------------------
-- Helpers defensivos: nada aqui debe poder crashear el juego
--------------------------------------------------------------

local function try(fn, default)
    local ok, res = pcall(fn)
    if ok and res ~= nil then return res end
    return default
end

-- Talisman y otros mods convierten los numeros grandes en tablas.
local function num(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    local ok, s = pcall(tostring, v)
    return ok and s or nil
end

--------------------------------------------------------------
-- De donde sale y a donde va el dinero
--------------------------------------------------------------

-- No hay que adivinar el origen: el propio juego reparte el cobro de fin de
-- ronda por categorias. Todas las filas que ves en el cash out pasan por
-- add_round_eval_row({name = ..., dollars = ...}) y ese name es la categoria
-- (blind, interest, hands, discards, joker, tag...).
--
-- Lo de fuera del cash out se coge en su sitio: ventas, compras y rerolls.
--
-- Y ease_dollars() es el paso obligado de CUALQUIER cambio de dinero, asi que
-- de ahi sale el total real. Restandole las categorias queda un resto sin
-- clasificar: si sale 0, la atribucion esta completa; si no, es que hay una
-- fuente que no contemplamos. Prefiero publicar ese resto a fingir que no
-- existe.
-- Los contadores viven DENTRO de G.GAME, no en una variable del mod.
--
-- save_run() guarda la partida con GAME = G.GAME entero (misc_functions.lua
-- :1611), asi que todo lo que cuelgue de ahi se guarda y se recupera solo. Si
-- se guardaran aparte, cerrar el juego a mitad de una partida y continuarla
-- despues perderia todo el dinero contado hasta ese momento: la partida
-- subiria con earned = 0 y solo lo que pasara despues de cargar.
--
-- Una partida nueva trae G.GAME limpio, asi que la tabla se crea vacia sola.
local function mny()
    local g = G.GAME
    if type(g) ~= "table" then return nil end
    local t = g.runtrk_money
    if type(t) ~= "table" then
        t = { earned = 0, spent = 0, rerolls = 0, from = {}, spent_on = {} }
        g.runtrk_money = t
    end
    -- Un guardado viejo puede no traerla entera, y recursive_table_cull se
    -- lleva por delante las tablas vacias.
    t.earned  = tonumber(t.earned)  or 0
    t.spent   = tonumber(t.spent)   or 0
    t.rerolls = tonumber(t.rerolls) or 0
    if type(t.from)     ~= "table" then t.from = {} end
    if type(t.spent_on) ~= "table" then t.spent_on = {} end
    return t
end

-- Hay cobros que no devuelven el dinero en su efecto: llaman a ease_dollars
-- directamente desde dentro. Los jokers Matador, Trading Card, Mail-In Rebate,
-- Faceless Joker y To Do List lo hacen dentro de Card:calculate_joker, y los
-- consumibles The Hermit, Temperance e Immolate dentro de Card:use_consumeable.
-- Como no hay nada en el importe que diga de donde viene, se marca quien tiene
-- el turno mientras dura la llamada y ease_dollars mira esa marca.
local money_ctx = nil
-- Contexto solo para el gasto. Hace falta aparte porque dentro de un descarte
-- tambien COBRAN jokers (Faceless Joker, Mail-In Rebate, Trading Card): si se
-- usara la misma marca para las dos direcciones, ese ingreso se etiquetaria
-- como coste de descarte.
local money_ctx_spend = nil

-- Ultimo recurso para un pago que llega sin marca de contexto: de que fichero
-- del juego viene la llamada. El closure vive en el fichero donde se escribio,
-- asi que esto funciona igual aunque se ejecute tres segundos despues.
--
-- Solo valen los ficheros que hacen UNA cosa. card.lua estuvo aqui como
-- "consumables" y era falso: ahi dentro estan tambien Card:calculate_joker
-- (Faceless Joker), Card:sell_card y Card:open, asi que todo lo que se pagara
-- con retraso desde card.lua acababa contado como consumible. Ahora los pagos
-- diferidos se llevan su marca puesta (ver el envoltorio de Event mas abajo),
-- y lo que siga sin marca es mas honesto que salga en "other".
local SOURCE_CATS = {
    ["tag.lua"]   = "tag",          -- Skip, Garbage, Handy, Economy
    ["blind.lua"] = "boss",         -- The Ox
}

--- Categoria segun quien llamo a ease_dollars. Nivel 3: esta funcion, el
--- envoltorio de ease_dollars, y el que lo llamo de verdad.
local function caller_category()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return nil end
    -- Sin pcall: envolverlo mete un nivel mas en la pila y se acaba leyendo
    -- el fichero equivocado. Un nivel que no existe devuelve nil, no error.
    local info = debug.getinfo(3, "S")
    local src = info and info.short_src
    if type(src) ~= "string" then return nil end
    src = src:gsub("\\", "/")
    for file, cat in pairs(SOURCE_CATS) do
        if src:sub(-#file) == file then return cat end
    end
    return nil
end

local function money_add(bucket, key, amount)
    if type(amount) ~= "number" or amount ~= amount or amount == 0 then return end
    if amount == math.huge or amount == -math.huge then return end
    local m = mny(); if not m then return end
    local t = m[bucket]
    t[key] = (t[key] or 0) + amount
end

--- Lo que se manda: las categorias que tienen algo, mas el resto.
local function money_summary()
    if not CFG.track_money then return nil end
    local m = mny()
    if not m then return nil end
    if m.earned == 0 and m.spent == 0 then return nil end

    local classified = 0
    local from = {}
    for k, v in pairs(m.from) do
        if v ~= 0 then from[k] = v; classified = classified + v end
    end
    local spent_classified = 0
    local spent_on = {}
    for k, v in pairs(m.spent_on) do
        if v ~= 0 then spent_on[k] = v; spent_classified = spent_classified + v end
    end

    -- El mismo resto para las dos mitades. El del gasto tambien hace falta:
    -- hay desafios que cobran por descartar, y sin esto no se veria.
    local rest = m.earned - classified
    if rest > 0.0001 or rest < -0.0001 then from.other = rest end
    local spent_rest = m.spent - spent_classified
    if spent_rest > 0.0001 or spent_rest < -0.0001 then spent_on.other = spent_rest end

    return {
        earned   = m.earned,
        spent    = m.spent,
        rerolls  = m.rerolls,
        from     = next(from) and from or nil,
        spent_on = next(spent_on) and spent_on or nil,
    }
end

--------------------------------------------------------------
-- Solo mazos del juego base
--------------------------------------------------------------

-- Misma idea que con los jokers, pero con otra consecuencia: una partida con
-- un mazo de otro mod SI se guarda en local (txt y jsonl), solo que no se
-- sube. En el ranking no tiene sentido comparar un mazo que los demas no
-- pueden jugar, pero en tu historial si lo quieres.
local VANILLA_DECKS = {}
for _, k in ipairs({
    "b_abandoned", "b_anaglyph", "b_black", "b_blue", "b_challenge",
    "b_checkered", "b_erratic", "b_ghost", "b_green", "b_magic",
    "b_nebula", "b_painted", "b_plasma", "b_red", "b_yellow", "b_zodiac"
}) do VANILLA_DECKS[k] = true end

--- Clave del mazo de la partida. selected_back_key guarda el center entero
--- (game.lua:2087, via get_deck_from_name), no la clave suelta.
local function deck_key()
    local g = G.GAME or {}
    local k = g.selected_back_key
    if type(k) == "table" then k = k.key end
    if type(k) ~= "string" then
        k = try(function() return g.selected_back.effect.center.key end)
    end
    if type(k) ~= "string" then
        -- Ultimo recurso: buscar el center por su nombre.
        local name = try(function() return g.selected_back.name end)
        if name then
            k = try(function()
                for key, v in pairs(G.P_CENTERS) do
                    if v.set == "Back" and v.name == name then return key end
                end
            end)
        end
    end
    return type(k) == "string" and k or nil
end

local function deck_is_vanilla()
    local k = deck_key()
    if not k then return true end        -- si no se puede saber, no se castiga
    return VANILLA_DECKS[k] == true
end

--------------------------------------------------------------
-- Recoleccion de datos de la partida
--------------------------------------------------------------

--------------------------------------------------------------
-- Valores internos de los jokers
--------------------------------------------------------------

-- Claves que el motor de puntuacion lee del efecto devuelto por
-- Card:calculate_joker. Balatro usa la familia *_mod; Steamodded normaliza
-- a los nombres cortos. Se aceptan las dos.
local EFFECT_KEYS = {
    mult_mod  = "mult",    mult   = "mult",    h_mult  = "mult",    t_mult  = "mult",
    chip_mod  = "chips",   chips  = "chips",   h_chips = "chips",   t_chips = "chips",
    Xmult_mod = "x_mult",  x_mult_mod = "x_mult", x_mult = "x_mult",
    Xmult     = "x_mult",  xmult  = "x_mult",  h_x_mult = "x_mult",
    dollars   = "dollars", p_dollars = "dollars", h_dollars = "dollars",
}

local ABILITY_SKIP = {
    order = true, type = true, set = true, name = true, effect = true,
    perish_tally = true,   -- se reporta aparte, junto a los stickers
}

--------------------------------------------------------------
-- Stickers (eternal / perishable / rental)
--------------------------------------------------------------

-- Los stickers viven en card.ability: ability.eternal, ability.perishable,
-- ability.rental. Perishable ademas lleva perish_tally, las rondas que le
-- quedan antes de desactivarse.
--
-- COMBINACIONES POSIBLES. En functions/common_events.lua el juego tira asi:
--
--     if     enable_eternals_in_shop    and poll > 0.7 then eternal
--     elseif enable_perishables_in_shop and poll > 0.4 and poll <= 0.7 then perishable
--     end
--     if enable_rentals_in_shop and pseudorandom('ssjr'..ante) > 0.7 then rental end
--
-- Eternal y perishable comparten UNA tirada con if/elseif: son excluyentes.
-- Rental es un if aparte con tirada propia, asi que se combina con cualquiera
-- de los otros dos (en Gold Stake estan las tres activas).
--   eternal + rental    -> posible
--   perishable + rental -> posible
--   eternal + perishable-> IMPOSIBLE, se avisa en el log si aparece
--
-- Steamodded permite stickers propios y los registra en SMODS.Stickers, asi
-- que se recorre esa tabla cuando existe y se cae a la lista base si no.
local BASE_STICKERS = { "eternal", "perishable", "rental" }

local STICKER_LABEL = {
    eternal    = "eternal",
    perishable = "perish",
    rental     = "rental",
}

--- Orden de referencia para que la linea salga siempre igual.
--- SMODS.Sticker define .order (eternal 1, perishable 2, rental 3); si falta,
--- se ordena alfabeticamente detras de los conocidos.
local STICKER_ORDER = { eternal = 1, perishable = 2, rental = 3 }

local function sticker_keys()
    local list = try(function()
        if type(SMODS) ~= "table" or type(SMODS.Stickers) ~= "table" then return nil end
        local ks, ord = {}, {}
        for k, v in pairs(SMODS.Stickers) do
            if type(k) == "string" then
                ks[#ks + 1] = k
                ord[k] = STICKER_ORDER[k]
                    or (type(v) == "table" and type(v.order) == "number" and 100 + v.order)
                    or 1000
            end
        end
        if #ks == 0 then return nil end
        table.sort(ks, function(a, b)
            if ord[a] ~= ord[b] then return ord[a] < ord[b] end
            return a < b
        end)
        return ks
    end)
    return list or BASE_STICKERS
end

--- Un sticker esta puesto si su entrada en ability no es nil ni false.
--- No se compara con `== true` a proposito: SMODS.Sticker:apply() guarda una
--- tabla de config en vez de un booleano cuando el sticker la define.
local function has_sticker(a, key)
    local v = a[key]
    return v ~= nil and v ~= false
end

--- Devuelve los stickers de una carta:
---   list  -> array de claves activas, p.ej. {"eternal","rental"}
---   flags -> { eternal = true, rental = true }
---   perish_tally -> rondas restantes si es perishable
---   conflict -> true si trae eternal y perishable a la vez (no deberia pasar)
local function collect_stickers(card)
    local a = card.ability
    if type(a) ~= "table" then return nil end

    local list, flags, any = array({}), {}, false
    local function add(key)
        if flags[key] or not has_sticker(a, key) then return end
        list[#list + 1] = key
        flags[key] = true
        any = true
    end

    for _, key in ipairs(sticker_keys()) do add(key) end
    -- Por si un sticker base no esta en SMODS.Stickers en alguna version.
    for _, key in ipairs(BASE_STICKERS) do add(key) end
    if not any then return nil end

    local tally = nil
    if flags.perishable and type(a.perish_tally) == "number"
       and a.perish_tally == a.perish_tally then
        tally = a.perish_tally
    end

    -- eternal + rental y perishable + rental son legitimas; eternal +
    -- perishable no puede salir del juego base. Si se da, se reporta tal cual
    -- (no se inventa nada) pero queda marcado para poder investigarlo.
    local conflict = (flags.eternal and flags.perishable) or nil
    return list, flags, tally, conflict
end

--- "[eternal] [perish 2] [rental]" para la linea del txt.
local function stickers_desc(j)
    local list = j and j.stickers
    if not list or #list == 0 then return "" end
    local out = {}
    for _, key in ipairs(list) do
        local label = STICKER_LABEL[key] or tostring(key)
        if key == "perishable" and j.perish_tally then
            label = label .. " " .. tostring(j.perish_tally)
        end
        out[#out + 1] = "[" .. label .. "]"
    end
    return " " .. table.concat(out, " ")
end

--------------------------------------------------------------
-- Cuantas rondas aguanta cada joker
--------------------------------------------------------------
--
-- La pregunta es "que jokers pasaron por mi fila y cuanto duraron". Se podria
-- enganchar Card:add_to_deck y Card:remove_from_deck, que es lo que suena
-- natural, y es un error: el juego los llama de mas.
--
--   * Card:set_ability hace remove + add por su cuenta (card.lua:255 y :483)
--     cada vez que una carta cambia de habilidad, sin que nadie la haya
--     comprado ni vendido.
--   * Debufar y desdebufar una fila llama a los dos con from_debuff (:717,
--     :722), asi que cada ciega jefe pareceria vender y recomprar todo.
--
-- Asi que no se escucha: se mira. Cada frame se pasa por G.jokers.cards y se
-- apunta quien esta; cuando el contador de rondas cambia, a todos los que
-- estan se les suma una. "Rondas que aguanto" acaba siendo literalmente eso,
-- las rondas en las que estaba, y da igual como entrara —comprado, de un
-- paquete, creado por Wraith o Riff-raff— y como saliera —vendido, muerto o
-- agotado—.
--
-- Vive en G.GAME, que save_run() serializa entero, asi que cerrar el juego a
-- mitad de partida no pierde la cuenta.

--- Identidad de una carta. sort_id es el contador que Balatro asigna a cada
--- carta creada (card.lua:24) y se guarda y restaura con la partida (:5110,
--- :5212). Se le pega la clave del joker porque ese contador NO se restaura
--- al cargar —solo lo hace cada carta— y dos cartas podrian acabar con el
--- mismo numero; con la clave delante, dos jokers distintos no se mezclan.
local function joker_hist_uid(card)
    local key = try(function() return card.config.center.key end) or "?"
    return tostring(card.sort_id or card.ID or card) .. ":" .. tostring(key)
end

--- El registro dentro de G.GAME, creado vacio en cuanto hace falta.
local function jhist()
    local g = G.GAME
    if type(g) ~= "table" then return nil end
    local t = g.runtrk_jokers
    if type(t) ~= "table" then
        t = { seen = {}, last_round = -1, n = 0 }
        g.runtrk_jokers = t
    end
    if type(t.seen) ~= "table" then t.seen = {} end
    t.last_round = tonumber(t.last_round) or -1
    -- Cuantas altas van. Es lo que da el orden de compra, y tiene que vivir
    -- aqui dentro: contarlo por fuera lo perderia al cargar la partida.
    t.n = tonumber(t.n) or 0
    return t
end

--- Una pasada por la fila. Es idempotente dentro de la misma ronda, asi que
--- llamarla cada frame no cuenta de mas: el alta se hace una vez por carta y
--- la suma de rondas solo cuando el contador de rondas se mueve.
local function sweep_jokers()
    if not CFG.track_joker_history then return end
    local area = G.jokers
    if type(area) ~= "table" or type(area.cards) ~= "table" then return end
    local t = jhist(); if not t then return end

    local round = tonumber(G.GAME.round) or 0
    local nueva = round ~= t.last_round

    for _, c in ipairs(area.cards) do
        if type(c) == "table" and try(function() return c.ability.set end) == "Joker" then
            local uid = joker_hist_uid(c)
            local e = t.seen[uid]
            if not e then
                -- Alta en cuanto aparece, no al cambiar de ronda: un joker
                -- comprado y revendido en la misma tienda no llega a ninguna
                -- ronda, pero paso por la fila y tiene que constar.
                -- Si aparece con la ciega en juego, esa ronda ya cuenta: los
                -- jokers de la tienda entran entre rondas y no deben llevarse
                -- la que todavia no han jugado, pero uno creado a mitad de
                -- mano (Seance, un paquete abierto en plena ronda) si estuvo
                -- ahi. G.GAME.blind.in_blind es justo esa diferencia
                -- (blind.lua:184, state_events.lua:95), y se guarda con la
                -- partida.
                --
                -- El "and not nueva" evita contar esa ronda dos veces: si el
                -- alta cae en el mismo frame en que el contador avanza, la
                -- suma de abajo ya se la da.
                local jugando = try(function() return G.GAME.blind.in_blind end) and true or false
                t.n = t.n + 1
                e = {
                    key   = try(function() return c.config.center.key end),
                    name  = try(function() return c.ability.name end),
                    from  = round,      -- contador de rondas al aparecer
                    rounds = (jugando and not nueva) and 1 or 0,
                    ord   = t.n,        -- el orden en que fueron llegando
                }
                t.seen[uid] = e
            end
            if nueva then e.rounds = (tonumber(e.rounds) or 0) + 1 end
        end
    end

    if nueva then t.last_round = round end
end

--- Lo que se manda: una entrada por joker que haya pasado por la fila, en el
--- orden en que fueron llegando. Dos copias del mismo joker van por separado,
--- que es lo que se quiere saber.
---
--- El orden importa y no se puede reconstruir en el otro lado: ni por rondas
--- —dos jokers comprados en la misma tienda empatan— ni por la ronda de alta,
--- por lo mismo. Asi que viaja ya ordenado.
---
--- Y cada entrada dice si esa carta sigue en la fila. Tambien hay que decirlo
--- desde aqui: en la lista que se manda solo van clave, nombre y rondas, asi
--- que con dos Baron y uno vendido el otro lado no tiene con que saber cual de
--- los dos se quedo. Aqui si, comparando la carta misma.
local function joker_history()
    if not CFG.track_joker_history then return nil end
    local t = jhist(); if not t then return nil end

    -- Los que siguen en la fila ahora mismo, por identidad de carta.
    local vivos = {}
    local area = G.jokers
    if type(area) == "table" and type(area.cards) == "table" then
        for _, c in ipairs(area.cards) do
            if type(c) == "table" and try(function() return c.ability.set end) == "Joker" then
                vivos[joker_hist_uid(c)] = true
            end
        end
    end

    local out = {}
    for uid, e in pairs(t.seen) do
        if e.key or e.name then
            out[#out + 1] = {
                key    = e.key,
                name   = e.name,
                rounds = tonumber(e.rounds) or 0,
                from   = tonumber(e.from),
                kept   = vivos[uid] or nil,   -- nil y no false: no ocupa sitio
                ord    = tonumber(e.ord) or 0,
            }
        end
    end
    if #out == 0 then return nil end
    -- Los de un guardado viejo no traen ord: van al final, por nombre, en vez
    -- de colarse todos al principio empatados a cero.
    table.sort(out, function(a, b)
        if (a.ord > 0) ~= (b.ord > 0) then return a.ord > 0 end
        if a.ord ~= b.ord then return a.ord < b.ord end
        return tostring(a.name) < tostring(b.name)
    end)
    -- ord ya no hace falta fuera: el orden esta en la lista.
    for _, e in ipairs(out) do e.ord = nil end
    return out
end

--- Maximo que ha llegado a dar cada joker durante la partida.
--- Clave: el sort_id que Balatro asigna a cada carta, asi dos copias del
--- mismo joker se cuentan por separado.
local joker_peaks = {}

local function joker_uid(card)
    return card.sort_id or card.ID or tostring(card)
end

local function is_finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Registra lo que un joker acaba de aportar, quedandose con lo mas alto.
local function record_effect(card, effect)
    local id = joker_uid(card)
    for k, v in pairs(effect) do
        local bucket = EFFECT_KEYS[k]
        if bucket and is_finite(v) then
            -- x1 y +0 no aportan informacion
            local neutral = (bucket == "x_mult" and v == 1) or (bucket ~= "x_mult" and v == 0)
            -- Un joker que paga al puntuar (Golden Joker, Business Card...)
            -- no pasa por el cash out, asi que se suma aqui.
            if bucket == "dollars" and not neutral and CFG.track_money then
                pcall(money_add, "from", "scoring_jokers", v)
            end
            if not neutral then
                local p = joker_peaks[id]
                if not p then p = {}; joker_peaks[id] = p end
                if not p[bucket] or v > p[bucket] then p[bucket] = v end
            end
        end
    end
end

--- Campos que multiplican, en cualquiera de sus variantes: x_mult, h_x_mult,
--- perma_x_mult, Xmult, x_chips, h_x_chips...
local MULT_MARKERS = { "x_mult", "xmult", "x_chips", "xchips" }

local function is_multiplicative(k)
    local lower = k:lower()
    for _, m in ipairs(MULT_MARKERS) do
        if lower:find(m, 1, true) then return true end
    end
    return false
end

--- Estado acumulado guardado en card.ability (Hologram, Green Joker, Rocket...).
--- Se queda solo con los numeros que dicen algo.
---
--- El neutro depende del tipo de campo: en los que multiplican es el 1, y en
--- los que suman es el 0. Pero en los que multiplican el 0 tampoco dice nada:
--- Balatro deja a cero los multiplicadores que ese joker no usa (perma_x_mult,
--- h_x_mult...), asi que si no se descartan aparecen en todas las partidas.
local function ability_values(card)
    local a = card.ability
    if type(a) ~= "table" then return nil end

    local out, any = {}, false
    local function put(k, v)
        if not is_finite(v) then return end
        if is_multiplicative(k) then
            if v == 1 or v == 0 then return end
        elseif v == 0 then
            return
        end
        out[k] = v
        any = true
    end

    for k, v in pairs(a) do
        if not ABILITY_SKIP[k] then
            if type(v) == "number" then
                put(k, v)
            elseif k == "extra" and type(v) == "table" then
                for k2, v2 in pairs(v) do
                    if type(v2) == "number" then put("extra_" .. tostring(k2), v2) end
                end
            end
        end
    end
    return any and out or nil
end

-- Mismo motivo que en enc_number: "%d" da la vuelta a los 32 bits y un joker
-- con un x-mult enorme saldria con un numero absurdo en la etiqueta.
local function fmt_num(v)
    if v % 1 == 0 then return string.format("%.0f", v) end
    return (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ""))
end

--- Numero que mejor resume lo que hace ese joker, con prioridad
--- xMult > +Mult > fichas > dinero. Prevalece lo medido durante la partida
--- sobre lo que este guardado en ability.
local function joker_headline(peak, abil)
    peak, abil = peak or {}, abil or {}
    local candidates = {
        { peak.x_mult  or abil.x_mult or abil.Xmult, "x_mult",  function(v) return "x" .. fmt_num(v) end },
        { peak.mult    or abil.mult,                 "mult",    function(v) return "+" .. fmt_num(v) end },
        { peak.chips   or abil.chips or abil.h_chips,"chips",   function(v) return "+" .. fmt_num(v) .. " chips" end },
        { peak.dollars or abil.p_dollars,            "dollars", function(v) return "$" .. fmt_num(v) end },
    }
    for _, c in ipairs(candidates) do
        local v, kind, show = c[1], c[2], c[3]
        if is_finite(v) and v ~= 0 and not (kind == "x_mult" and v == 1) then
            return v, kind, show(v)
        end
    end
    return nil
end

--------------------------------------------------------------
-- Solo partidas con los 150 jokers de base
--------------------------------------------------------------

-- Lista sacada de la tabla de jokers del propio juego (game.lua). Si un mod
-- anade jokers, sus claves llevan prefijo propio y no estan aqui, asi que la
-- partida se descarta y no ensucia el ranking.
local VANILLA_JOKERS = {}
for _, k in ipairs({
    "j_joker", "j_greedy_joker", "j_lusty_joker", "j_wrathful_joker",
    "j_gluttenous_joker", "j_jolly", "j_zany", "j_mad", "j_crazy",
    "j_droll", "j_sly", "j_wily", "j_clever", "j_devious", "j_crafty",
    "j_half", "j_stencil", "j_four_fingers", "j_mime", "j_credit_card",
    "j_ceremonial", "j_banner", "j_mystic_summit", "j_marble",
    "j_loyalty_card", "j_8_ball", "j_misprint", "j_dusk", "j_raised_fist",
    "j_chaos", "j_fibonacci", "j_steel_joker", "j_scary_face",
    "j_abstract", "j_delayed_grat", "j_hack", "j_pareidolia",
    "j_gros_michel", "j_even_steven", "j_odd_todd", "j_scholar",
    "j_business", "j_supernova", "j_ride_the_bus", "j_space", "j_egg",
    "j_burglar", "j_blackboard", "j_runner", "j_ice_cream", "j_dna",
    "j_splash", "j_blue_joker", "j_sixth_sense", "j_constellation",
    "j_hiker", "j_faceless", "j_green_joker", "j_superposition",
    "j_todo_list", "j_cavendish", "j_card_sharp", "j_red_card",
    "j_madness", "j_square", "j_seance", "j_riff_raff", "j_vampire",
    "j_shortcut", "j_hologram", "j_vagabond", "j_baron", "j_cloud_9",
    "j_rocket", "j_obelisk", "j_midas_mask", "j_luchador", "j_photograph",
    "j_gift", "j_turtle_bean", "j_erosion", "j_reserved_parking", "j_mail",
    "j_to_the_moon", "j_hallucination", "j_fortune_teller", "j_juggler",
    "j_drunkard", "j_stone", "j_golden", "j_lucky_cat", "j_baseball",
    "j_bull", "j_diet_cola", "j_trading", "j_flash", "j_popcorn",
    "j_trousers", "j_ancient", "j_ramen", "j_walkie_talkie", "j_selzer",
    "j_castle", "j_smiley", "j_campfire", "j_ticket", "j_mr_bones",
    "j_acrobat", "j_sock_and_buskin", "j_swashbuckler", "j_troubadour",
    "j_certificate", "j_smeared", "j_throwback", "j_hanging_chad",
    "j_rough_gem", "j_bloodstone", "j_arrowhead", "j_onyx_agate",
    "j_glass", "j_ring_master", "j_flower_pot", "j_blueprint", "j_wee",
    "j_merry_andy", "j_oops", "j_idol", "j_seeing_double", "j_matador",
    "j_hit_the_road", "j_duo", "j_trio", "j_family", "j_order", "j_tribe",
    "j_stuntman", "j_invisible", "j_brainstorm", "j_satellite",
    "j_shoot_the_moon", "j_drivers_license", "j_cartomancer",
    "j_astronomer", "j_burnt", "j_bootstraps", "j_caino", "j_triboulet",
    "j_yorick", "j_chicot", "j_perkeo"
}) do VANILLA_JOKERS[k] = true end

--- Primer joker de fuera de la lista que se ha visto en la partida.
--- nil = la run sigue siendo limpia.
local modded_joker_seen = nil

--- Solo mira jokers: mazos, tarots, stakes y demas se dejan pasar.
local function check_vanilla(center)
    if modded_joker_seen then return end
    if type(center) ~= "table" or center.set ~= "Joker" then return end
    local key = center.key
    if type(key) ~= "string" or not VANILLA_JOKERS[key] then
        modded_joker_seen = (type(key) == "string" and key)
            or (type(center.name) == "string" and center.name) or "?"
        log("modded joker detected (" .. modded_joker_seen ..
            "): this run will not be recorded")
    end
end

--- Repaso de los jokers que hay ahora mismo en la mano.
--- Hace falta ademas del hook de add_to_deck porque al cargar una partida
--- guardada las cartas se reconstruyen con CardArea:load y ese hook no salta.
local function scan_jokers_for_mods()
    if modded_joker_seen then return end
    if not (G.jokers and G.jokers.cards) then return end
    for _, c in ipairs(G.jokers.cards) do
        check_vanilla(c.config and c.config.center)
        if modded_joker_seen then return end
    end
end

-- Las doce manos de poker, en el orden en que las ensena el juego (handlist
-- de globals.lua): de la mejor a la peor. Se fija aqui y no se saca de
-- G.GAME.hands porque una tabla de Lua no tiene orden.
local HANDLIST = {
    "Flush Five", "Flush House", "Five of a Kind", "Straight Flush",
    "Four of a Kind", "Full House", "Flush", "Straight",
    "Three of a Kind", "Two Pair", "Pair", "High Card",
}

-- Nivel y veces jugada de cada mano al cerrar la partida.
--
-- El juego ya lleva esta cuenta el solo en G.GAME.hands, asi que no hay nada
-- que ir contando durante la run: se lee entera de una vez al final.
--
-- Se guarda tambien "visible": las tres manos secretas (Flush Five, Flush
-- House, Five of a Kind) no existen para el jugador hasta que las descubre, y
-- en el cuadro del juego salen como ??? . Sin ese dato la web no podria
-- distinguir "nivel 1, nunca jugada" de "ni sabias que existia".
--
-- Los niveles son los del FINAL de la partida, no un historico: se sabe a que
-- nivel llego cada mano, no cuando subio.
local function collect_hands()
    if not CFG.track_hands then return nil end
    local hands = G.GAME and G.GAME.hands
    if type(hands) ~= "table" then return nil end
    local out = {}
    local alguna = false
    for _, name in ipairs(HANDLIST) do
        local h = hands[name]
        if type(h) == "table" then
            out[name] = {
                level   = num(h.level),
                played  = num(h.played),
                chips   = num(h.chips),
                mult    = num(h.mult),
                visible = h.visible and true or false,
            }
            alguna = true
        end
    end
    -- Sin ninguna mano no se manda la clave: mejor que no venga a que venga
    -- un objeto vacio que la web tenga que distinguir de "no medido".
    if not alguna then return nil end
    return out
end

local function collect_jokers()
    local out = array({})
    if not CFG.include_jokers then return out end
    if not (G.jokers and G.jokers.cards) then return out end
    for _, c in ipairs(G.jokers.cards) do
        local center = c.config and c.config.center
        local abil = CFG.track_joker_values and try(function() return ability_values(c) end) or nil
        local peak = CFG.track_joker_values and joker_peaks[joker_uid(c)] or nil
        local value, kind, display = joker_headline(peak, abil)
        local st = try(function()
            local l, f, t, x = collect_stickers(c)
            return { l, f, t, x }
        end, {})
        local stickers, flags, tally, conflict = st[1], st[2] or {}, st[3], st[4]
        if conflict then
            log("WARNING: " .. tostring((center and center.name) or "joker") ..
                " is both eternal and perishable, which the base game cannot" ..
                " produce (they share a single if/elseif roll)." ..
                " Logged as-is; check whether another mod is applying them.", "error")
        end
        out[#out + 1] = {
            key     = center and center.key or nil,
            name    = center and center.name or nil,
            edition = c.edition and c.edition.key or nil,
            ability = abil,       -- estado acumulado (x_mult, mult, extra_*...)
            peak    = peak,       -- lo mas alto que llego a aportar de verdad
            value   = value,      -- el numero que lo resume
            value_type = kind,    -- "x_mult" | "mult" | "chips" | "dollars"
            display = display,    -- "x4.25", "+51", "+120 fichas"
            stickers   = stickers,          -- {"eternal","rental"} o nil
            eternal    = flags.eternal or nil,
            perishable = flags.perishable or nil,
            rental     = flags.rental or nil,
            perish_tally = tally,           -- rondas que le quedan
            sticker_conflict = conflict,    -- eternal + perishable: imposible
        }
    end
    return out
end

--- Identidad de Steam. Balatro carga luasteam en G.STEAM (solo Windows y macOS).
--- luasteam devuelve el SteamID64 como *userdata* precisamente porque un numero
--- de Lua (double, 53 bits) no puede representar 64 bits sin perder digitos:
--- por eso hay que pasarlo por tostring() y no por tonumber().
local function steam_id_to_string(id)
    local t = type(id)
    if t == "string" then
        return id, true
    elseif t == "userdata" or t == "cdata" or t == "table" then
        local s = try(function() return tostring(id) end)
        if s then
            s = s:gsub("[uUlL]+$", "")
            -- Descarta "userdata: 0x7f..." y similares: solo digitos.
            if s:match("^%d+$") then return s, true end
        end
    elseif t == "number" then
        -- Version antigua que devuelve un double: los ultimos digitos pueden
        -- no ser fiables, se marca como no exacto.
        return string.format("%.0f", id), id < 9007199254740992
    end
    return nil, false
end

local function collect_steam()
    local info = {}
    if not CFG.send_steam_id then return info end
    local S = G.STEAM
    if not S then return info end

    local raw = try(function() return S.user.getSteamID() end)
    if raw ~= nil then
        local id, exact = steam_id_to_string(raw)
        info.id = id
        info.exact = exact
        -- No hay getPersonaName() en luasteam: se pide el nombre del "amigo"
        -- que eres tu mismo pasando tu propio ID.
        info.name = try(function() return S.friends.getFriendPersonaName(raw) end)
    end
    if info.name == "" or info.name == "[unknown]" then info.name = nil end
    return info
end

--------------------------------------------------------------
-- Identidad: nombre de subida y codigo de usuario
--------------------------------------------------------------

-- Estos dos valores se editan desde la config del mod (Mods > Run Tracker >
-- Config) y Steamodded los guarda en config/RunTracker.jkr. Los valores por
-- defecto viven en config.lua.
MOD.config = MOD.config or {}
local UI = MOD.config
if type(UI.player_name) ~= "string" then UI.player_name = "" end
if type(UI.user_code)   ~= "string" then UI.user_code   = "" end
if type(UI.user_tag)    ~= "string" then UI.user_tag    = "" end
if type(UI.upload)      ~= "boolean" then UI.upload      = true end
if type(UI.notice_seen) ~= "boolean" then UI.notice_seen = false end
-- Los cuadernos abiertos. Se filtra al cargar porque esto viaja en un .jkr
-- que se puede editar a mano, y un nombre raro aqui acabaria siendo un
-- nombre de fichero raro.
if type(UI.extra_logs) ~= "table" then UI.extra_logs = {} end

--- SteamID64 en crudo. Se lee aunque send_steam_id este desactivado: el
--- codigo de usuario es un hash y el ID en si no sale de tu maquina.
local function raw_steam_id()
    local S = G and G.STEAM
    if not S then return nil end
    local raw = try(function() return S.user.getSteamID() end)
    if raw == nil then return nil end
    return (steam_id_to_string(raw))
end

local function steam_persona()
    local S = G and G.STEAM
    if not S then return nil end
    local raw = try(function() return S.user.getSteamID() end)
    if raw == nil then return nil end
    local n = try(function() return S.friends.getFriendPersonaName(raw) end)
    if n == "" or n == "[unknown]" then return nil end
    return n
end

-- Alfabeto Crockford base32: sin I, L, O ni U, para que nadie confunda un
-- 1 con una I al dictar su codigo.
local CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

--- Dos hashes independientes. Se usan multiplicadores y modulos pequenos a
--- proposito: Lua trabaja con doubles y asi el producto nunca pasa de 2^53,
--- que es donde dejarian de ser exactos.
local function hash_pair(s)
    local h1, h2 = 2166136261 % 2147483647, 5381
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 131 + b) % 2147483647
        h2 = (h2 * 33 + b) % 1073741789
    end
    return h1, h2
end

--- Mezcla final. Sin esto dos SteamID consecutivos (los de dos amigos, por
--- ejemplo) salen con codigos casi identicos, y eso confunde al compararlos.
--- Los multiplicadores son primos por debajo de 2^21 para que el producto
--- siga cabiendo exacto en un double.
local function mix(a, b)
    a = (a * 2097143 + b + 1) % 2147483647
    b = (b * 1048573 + a + 1) % 1073741789
    return a, b
end

--- 8 caracteres: "RT-7K3F9AQ2". Determinista, asi que el mismo SteamID da
--- siempre el mismo codigo aunque reinstales el juego o cambies de PC.
--- Se remezcla en cada caracter y se cogen bits del medio, no los de mas
--- abajo: los ultimos bits de una aritmetica modular tienen sesgo.
local function short_code(s)
    local a, b = hash_pair(s)
    a, b = mix(a, b)
    a, b = mix(a, b)
    local out = {}
    for i = 1, 8 do
        a, b = mix(a, b)
        local n = math.floor(a / 64) % 32
        out[i] = CODE_ALPHABET:sub(n + 1, n + 1)
    end
    return "RT-" .. table.concat(out)
end

--- Sin Steam no hay de donde derivarlo: se sortea uno y se guarda.
local function random_code()
    local out = {}
    for _ = 1, 8 do
        local n = math.random(1, #CODE_ALPHABET)
        out[#out + 1] = CODE_ALPHABET:sub(n, n)
    end
    return "RT-" .. table.concat(out)
end

--- Nombre del perfil de Balatro. Es el respaldo cuando no hay Steam: luasteam
--- solo esta si el juego arranca desde Steam con su API inicializada, y en
--- muchas instalaciones no lo esta.
--- Se ignora el valor por defecto ("P1", "P2"...), que no identifica a nadie.
local function profile_name()
    local p = G and G.PROFILES and G.SETTINGS and G.PROFILES[G.SETTINGS.profile]
    local n = p and p.name
    if type(n) ~= "string" or n == "" then return nil end
    if n:match("^P%d+$") then return nil end
    return n
end

--- Nombre con el que se suben las partidas. Se coge el primero que haya:
---   1. lo escrito en la config del mod
---   2. player_name de settings.lua (compatibilidad)
---   3. tu nombre de Steam
---   4. el nombre de tu perfil de Balatro
---   5. "Anonymous"
--- El numero de cuatro cifras se pega despues, asi que dos "Anonymous" nunca
--- se confunden entre si.
local function resolved_player_name()
    if UI.player_name ~= "" then return UI.player_name end
    if type(CFG.player_name) == "string" and CFG.player_name ~= "" then
        return CFG.player_name
    end
    return steam_persona() or profile_name() or "Anonymous"
end

--- Numero de cuatro cifras que se pega al nombre: "TimelessC1#0042".
--- No se usa math.randomseed a proposito: el juego siembra math.random con
--- G.SEED y tocarlo desde aqui podria afectar a las tiradas de la partida.
--- En su lugar se mezclan varias fuentes de entropia que ya estan a mano.
local function random_tag()
    local t = tonumber(os.time()) or 0
    local c = math.floor((tonumber(os.clock()) or 0) * 1000000)
    local r = math.random(0, 9999)
    -- La direccion de una tabla recien creada varia en cada arranque.
    local addr = tonumber((tostring({}):match("0x(%x+)") or "0"):sub(-8), 16) or 0
    local n = (t * 7919 + c * 104729 + r * 31 + addr) % 10000
    return string.format("%04d", n)
end

--------------------------------------------------------------
-- Identidad persistente
--------------------------------------------------------------

-- El codigo y el numero del nombre viven en un fichero propio dentro de la
-- carpeta de guardado de Balatro, al lado de los resultados. Steamodded ya
-- guarda la config en config/RunTracker.jkr, pero eso es "del mod": este
-- fichero es tuyo y sigue ahi aunque borres la carpeta del mod.
local IDENTITY_FILE = "run_tracker_identity.txt"

local function identity_path()
    local dir = try(function() return love.filesystem.getSaveDirectory() end)
    if not dir or dir == "" then return nil end
    return dir .. "/" .. IDENTITY_FILE
end

--- Lee el fichero por las dos vias, igual que el txt de resultados:
--- love.filesystem no siempre ve lo que escribio el fallback io.open.
local function read_identity()
    local raw = try(function()
        if not love.filesystem.getInfo(IDENTITY_FILE) then return nil end
        return (love.filesystem.read(IDENTITY_FILE))
    end)
    if not raw then
        local path = identity_path()
        if path then
            local fh = io.open(path, "r")
            if fh then raw = fh:read("*a") fh:close() end
        end
    end
    if type(raw) ~= "string" then return {} end

    local out = {}
    for k, v in raw:gmatch("([%w_]+)%s*=%s*([^\r\n]*)") do
        out[k] = (v:gsub("%s+$", ""))
    end
    return out
end

local function write_identity(code, tag)
    local body = table.concat({
        "# Balatro Run Tracker - identity",
        "# Keep this file: it is what makes your user code and name tag",
        "# survive reinstalling or deleting the mod.",
        "user_code=" .. tostring(code or ""),
        "user_tag=" .. tostring(tag or ""),
        "",
    }, "\n")

    local ok = pcall(love.filesystem.write, IDENTITY_FILE, body)
    if ok and try(function() return love.filesystem.getInfo(IDENTITY_FILE) end) then
        return true
    end
    local path = identity_path()
    if path then
        local fh = io.open(path, "w")
        if fh then fh:write(body) fh:close() return true end
    end
    log("could not write " .. IDENTITY_FILE, "error")
    return false
end

local function valid_tag(v)  return type(v) == "string" and v:match("^%d%d%d%d$") ~= nil end
local function valid_code(v) return type(v) == "string" and v:match("^RT%-[0-9A-Z]+$") ~= nil end

--- Codigo y numero se resuelven juntos: los dos salen del mismo fichero y
--- asi solo se escribe una vez.
--- Orden: fichero de identidad > config del mod > se genera.
local identity_done = false
local function resolve_identity()
    if identity_done then return UI.user_code, UI.user_tag end
    identity_done = true

    local saved = read_identity()
    local code = valid_code(saved.user_code) and saved.user_code
              or (valid_code(UI.user_code) and UI.user_code) or nil
    local tag  = valid_tag(saved.user_tag) and saved.user_tag
              or (valid_tag(UI.user_tag) and UI.user_tag) or nil

    if not code then
        local sid = raw_steam_id()
        if sid then
            code = short_code("runtrk:" .. sid)
            UI.user_code_source = "steam"
        else
            code = random_code()
            UI.user_code_source = "random"
        end
        log("user code generated: " .. code .. " (" .. UI.user_code_source .. ")")
    end
    if not tag then
        tag = random_tag()
        log("name tag generated: #" .. tag)
    end

    UI.user_code, UI.user_tag = code, tag
    if UI.user_code_source == "" then UI.user_code_source = "restored" end
    pcall(SMODS.save_mod_config, MOD)
    if saved.user_code ~= code or saved.user_tag ~= tag then
        write_identity(code, tag)
    end
    return code, tag
end

local function resolved_user_code()
    local code = select(1, resolve_identity())
    return code
end

--- Numero de cuatro cifras del nombre. Se genera una vez y no se toca.
local function resolved_user_tag()
    local _, tag = resolve_identity()
    return tag
end

--- "TimelessC1#0042": lo que se ve en la web.
local function resolved_display_name()
    return resolved_player_name() .. "#" .. resolved_user_tag()
end

--- Colores reales de las fichas de apuesta (tomados de G.C en globals.lua).
local STAKE_HEX = {
    white = "CDD9DC", red    = "FE5F55", green  = "4BC292", black = "374244",
    blue  = "009DFF", purple = "8867A5", orange = "FDA200", gold  = "EAC058",
}

--- Convierte una tabla de color de LOVE {r,g,b,a} en hexadecimal.
local function to_hex(c)
    if type(c) ~= "table" or not c[1] or not c[2] or not c[3] then return nil end
    return string.format("%02X%02X%02X",
        math.floor((c[1] or 0) * 255 + 0.5),
        math.floor((c[2] or 0) * 255 + 0.5),
        math.floor((c[3] or 0) * 255 + 0.5))
end

--- Apuesta (stake) de la partida: nivel, clave, color y nombre localizado.
--- G.GAME.stake es un numero 1..8; G.P_STAKES lo relaciona con stake_white,
--- stake_red, etc. Se usa antes G.P_CENTER_POOLS.Stake para que las stakes
--- anadidas por otros mods tambien funcionen.
local function collect_stake()
    local info = {}
    local st = G.GAME and G.GAME.stake
    if st == nil then return info end

    local key, center
    if type(st) == "string" then
        key = st
        center = G.P_STAKES and G.P_STAKES[st] or nil
    else
        info.level = st
        center = try(function() return G.P_CENTER_POOLS.Stake[st] end)
        key = center and center.key or nil
        if not key and G.P_STAKES then
            for k, v in pairs(G.P_STAKES) do
                if v.stake_level == st or v.order == st then
                    key, center = k, v
                    break
                end
            end
        end
    end
    if not key then return info end

    local word = key:gsub("^stake_", "")
    info.key    = key
    info.colour = word:sub(1, 1):upper() .. word:sub(2)   -- White, Red, Green...
    info.label  = info.colour .. " Stake"                 -- "Green Stake"
    info.name   = try(function() return localize({ type = "name_text", key = key, set = "Stake" }) end)
                  or (center and center.name) or nil
    info.hex    = (center and to_hex(center.colour)) or STAKE_HEX[word]
    info.level  = info.level or (center and (center.stake_level or center.order)) or nil
    return info
end

--- Ciega en la que termino la partida.
--- Blind:get_type() devuelve 'Small' | 'Big' | 'Boss' segun el nombre.
--- En las boss el nombre localizado esta en loc_name y la clave estable
--- (bl_hook, bl_wall...) en config.blind.key.
local function collect_blind()
    local info = {}
    local b = G.GAME and G.GAME.blind

    if not b or not b.name or b.name == "" then
        -- La ciega se limpia al derrotarla; last_blind conserva la ultima.
        local lb = G.GAME and G.GAME.last_blind
        if lb and lb.name and lb.name ~= "" then
            info.name = lb.name
            info.type = lb.boss and "Boss"
                or (lb.name == "Small Blind" and "Small")
                or (lb.name == "Big Blind" and "Big") or nil
        end
        return info
    end

    info.type = try(function() return b:get_type() end)
    if not info.type then
        info.type = (b.name == "Small Blind" and "Small")
            or (b.name == "Big Blind" and "Big")
            or (b.boss and "Boss") or nil
    end

    info.name = b.loc_name
    if not info.name or info.name == "" then info.name = b.name end
    info.key      = try(function() return b.config.blind.key end)
    info.chips    = num(b.chips)
    info.disabled = b.disabled and true or nil
    return info
end

local function build_payload(result)
    local g = G.GAME or {}
    local blind = collect_blind()
    local stake = collect_stake()
    local steam = collect_steam()
    -- Comprobacion independiente: la puntuacion, alcanzo el objetivo?
    local beat_the_blind_value = nil
    if type(g.chips) == "number" and type(blind.chips) == "number" then
        beat_the_blind_value = g.chips >= blind.chips
    end
    return {
        schema       = 1,
        mod_version  = MOD and MOD.version or nil,
        result       = result,                              -- "win" | "loss"
        won          = (result == "win"),
        seed         = try(function() return g.pseudorandom.seed end),
        ante         = try(function() return g.round_resets.ante end),
        win_ante     = num(g.win_ante),
        round        = num(g.round),
        hands_played = num(g.hands_played),
        skips        = num(g.skips),
        dollars      = num(g.dollars),
        best_hand    = num(try(function() return g.round_scores.hand.amt end)),
        deck         = try(function() return g.selected_back.name end)
                       or try(function() return g.selected_back_key end),
        -- El nombre del mazo llega traducido si juegas en otro idioma; la
        -- clave no. La web se queda con la clave para agrupar.
        deck_key     = try(deck_key),
        stake          = num(g.stake),
        stake_level    = stake.level,     -- 1..8
        stake_key      = stake.key,       -- "stake_green"
        stake_colour   = stake.colour,    -- "Green"
        stake_label    = stake.label,     -- "Green Stake"
        stake_name     = stake.name,      -- nombre localizado ("Ficha Verde")
        stake_hex      = stake.hex,       -- "4BC292"
        blind_type     = blind.type,      -- "Small" | "Big" | "Boss"
        blind_name     = blind.name,      -- "Small Blind" | "The Hook" | ...
        blind_key      = blind.key,       -- "bl_small" | "bl_hook" | ...
        blind_chips    = blind.chips,     -- puntuacion que pedia la ciega
        round_score    = num(g.chips),    -- puntuacion conseguida en esa ronda
        round_pct      = (type(g.chips) == "number" and type(blind.chips) == "number"
                          and blind.chips > 0)
                         and (100 * g.chips / blind.chips) or nil,
        beat_blind     = beat_the_blind_value,
        blind_disabled = blind.disabled,  -- true si estaba anulada (Chicot...)
        challenge    = g.challenge or nil,
        seeded       = g.seeded and true or false,
        jokers       = collect_jokers(),
        money        = try(money_summary),
        -- Cada joker que paso por la fila y cuantas rondas aguanto.
        joker_history = try(joker_history),
        hands        = try(collect_hands),
        game_version = try(function() return G.VERSION end),
        platform     = try(function() return love.system.getOS() end),
        player         = try(resolved_player_name),   -- "TimelessC1"
        player_tag     = try(resolved_user_tag),      -- "0042"
        player_display = try(resolved_display_name),  -- "TimelessC1#0042"
        user_code      = try(resolved_user_code),     -- "RT-7K3F9AQ2", clave estable
        user_code_source = UI.user_code_source,       -- "steam" | "random"
        steam_id       = steam.id,        -- SteamID64 como texto
        steam_name     = steam.name,      -- nombre visible en Steam
        steam_id_exact = steam.id and steam.exact or nil,
        played_at    = os.time(),
    }
end

--------------------------------------------------------------
-- Persistencia local
--------------------------------------------------------------

local function append_file(file, line)
    pcall(function()
        love.filesystem.append(file, line .. "\n")
    end)
end

--------------------------------------------------------------
-- Cuadernos: logs extra, temporales, ademas del de siempre
--------------------------------------------------------------
--
-- La idea: "quiero medir mis partidas de octubre". Abres un cuaderno
-- llamado "Desafio Octubre" y a partir de ahi cada partida que acabes se
-- escribe DOS veces, en run_tracker_log.jsonl y en
-- run_tracker_log_Desafio_Octubre.jsonl. Cuando el mes acaba, lo cierras y
-- te queda ese fichero con justo esas partidas, listo para cargarlo en la
-- pestana "My stats" de la web.
--
-- El log general nunca se toca: sigue llevandolo todo, pase lo que pase con
-- los cuadernos. Y cerrar uno no borra nada, solo deja de escribir en el.

--- Tope de cuadernos a la vez. No hay razon para tener treinta, y cada uno
--- es una escritura mas por partida.
local MAX_EXTRA_LOGS = 8

--- El nombre que escribe el jugador se convierte en parte de un nombre de
--- fichero, asi que no puede pasar tal cual: los espacios se vuelven guiones
--- bajos y lo que no sea letra, cifra, guion o guion bajo se cae. Sin esto,
--- un "Octubre/2026" o un "..\\..\\algo" escribirian donde no deben.
---
--- Devuelve nil si no queda nada aprovechable.
local function clean_label(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_")
    -- Byte a byte, no por patron de clase: los acentos son multibyte en UTF-8
    -- y %w no los reconoce, asi que se quedarian a medias.
    s = s:gsub("[^%w_%-]", "")
    s = s:gsub("_+", "_"):gsub("^[_%-]+", ""):gsub("[_%-]+$", "")
    if s == "" then return nil end
    return s:sub(1, 40)
end

--- run_tracker_log_Desafio_Octubre.jsonl. Mismo prefijo y misma extension
--- que el log general a proposito: se ordenan juntos en la carpeta y la web
--- los reconoce igual.
local function extra_log_file(label)
    return "run_tracker_log_" .. label .. ".jsonl"
end

--- Los cuadernos abiertos, ya limpios y sin repetidos.
local function extra_logs()
    local out, seen = {}, {}
    for _, v in ipairs(UI.extra_logs or {}) do
        local c = clean_label(v)
        if c and not seen[c:lower()] then
            seen[c:lower()] = true
            out[#out + 1] = c
        end
    end
    return out
end

--- Tope para que un servidor caido no llene el disco de partidas pendientes.
local MAX_PENDING = 500

local function count_lines(file)
    local n = 0
    pcall(function()
        if not love.filesystem.getInfo(file) then return end
        for _ in love.filesystem.lines(file) do n = n + 1 end
    end)
    return n
end

local function queue_pending(body)
    if count_lines(PENDING_FILE) >= MAX_PENDING then
        log("pending queue full (" .. MAX_PENDING .. "); run kept only in " ..
            TXT_FILE, "error")
        return
    end
    append_file(PENDING_FILE, body)
end

local function read_lines(file)
    local lines = {}
    pcall(function()
        if not love.filesystem.getInfo(file) then return end
        for line in love.filesystem.lines(file) do
            if line ~= "" then lines[#lines + 1] = line end
        end
    end)
    return lines
end

--------------------------------------------------------------
-- Salida legible en texto plano
--------------------------------------------------------------

local TXT_HEADER =
    "# Balatro Run Tracker - results\n" ..
    "# date | result | seed | ante | round | blind | points | deck, stake | best hand | jokers\n" ..
    "# joker stickers: [eternal] [perish N] [rental]  (N = rounds left)\n"

--- Puntuaciones enormes: 1234 -> "1234", 8.4e12 -> "8.4e+12".
local function fmt_score(v)
    if type(v) ~= "number" or v ~= v then return "?" end
    if math.abs(v) < 1e15 and v % 1 == 0 then return string.format("%.0f", v) end
    return string.format("%.3g", v)
end

--- "111144/300000 (37.0%)": lo conseguido, lo que pedia la ciega y el porcentaje.
local function score_desc(p)
    local got, need = p.round_score, p.blind_chips
    if type(got) ~= "number" then return "?" end
    if type(need) ~= "number" or need <= 0 then return fmt_score(got) .. "/?" end
    return string.format("%s/%s (%.1f%%)", fmt_score(got), fmt_score(need), 100 * got / need)
end

--- Apuesta con su color: "stake 3 Green".
local function stake_desc(p)
    if p.stake_label then return p.stake_label end
    local n = p.stake_level or (type(p.stake) == "number" and p.stake) or nil
    return n and ("Stake " .. n) or "Stake ?"
end

--- Descripcion corta de la ciega: "Small Blind", "Big Blind" o el nombre
--- del jefe tal cual ("The Needle").
local function blind_desc(p)
    local name = p.blind_name
    if p.blind_type == "Small" then
        name = "Small Blind"
    elseif p.blind_type == "Big" then
        name = "Big Blind"
    end
    if not name or name == "" then return "?" end
    return tostring(name) .. (p.blind_disabled and " (disabled)" or "")
end

local function joker_summary(list)
    local names = {}
    for _, j in ipairs(list or {}) do
        local n = j.name or j.key or "?"
        if j.edition then n = n .. " (" .. tostring(j.edition):gsub("^e_", "") .. ")" end
        n = n .. stickers_desc(j)
        if j.display then n = n .. " " .. j.display end
        names[#names + 1] = n
    end
    if #names == 0 then return "-" end
    return table.concat(names, ", ")
end

--- Ruta absoluta de un fichero dentro de la carpeta de guardado de Balatro.
local function save_path(name)
    local dir = try(function() return love.filesystem.getSaveDirectory() end)
    if not dir or dir == "" then return nil end
    return dir .. "/" .. name
end

--- Escribe en el txt. Intenta love.filesystem y, si no cuaja, cae a io.open
--- con la ruta absoluta. Si fallan las dos, lo dice bien alto en el log.
local function txt_append(text)
    local ok, err = pcall(love.filesystem.append, TXT_FILE, text)
    if ok and try(function() return love.filesystem.getInfo(TXT_FILE) end) then
        return true
    end

    local path = save_path(TXT_FILE)
    if path then
        local fh = io.open(path, "a")
        if fh then
            fh:write(text)
            fh:close()
            log("txt written through the fallback path (io.open): " .. path)
            return true
        end
    end

    log("COULD NOT WRITE " .. TXT_FILE ..
        " with love.filesystem (" .. tostring(err) ..
        ") nor with io.open at " .. tostring(path), "error")
    return false
end

--- La cabecera se escribe una sola vez, y solo si el fichero no existe ya.
--- Comprueba por las dos vias porque love.filesystem puede no ver el fichero
--- que escribio el fallback io.open.
local header_checked = false
local function ensure_header()
    if header_checked then return end
    header_checked = true

    local exists = try(function() return love.filesystem.getInfo(TXT_FILE) end) and true or false
    if not exists then
        local path = save_path(TXT_FILE)
        if path then
            local fh = io.open(path, "r")
            if fh then fh:close() exists = true end
        end
    end
    if not exists then txt_append(TXT_HEADER) end
end

local function write_txt(p)
    if not CFG.write_txt then return end
    local ok, err = pcall(function()
        ensure_header()
        local line = string.format(
            "%s | %-4s | %-10s | Ante %-2s | Round %-2s | %-22s | Pts %-26s | %s, %s | Best hand: %s | %s",
            os.date("%Y-%m-%d %H:%M:%S"),
            p.result == "win" and "WIN" or "LOSE",
            tostring(p.seed or "?"),
            tostring(p.ante or "?"),
            tostring(p.round or "?"),
            blind_desc(p),
            score_desc(p),
            tostring(p.deck or "?"),
            stake_desc(p),
            tostring(p.best_hand or 0),
            joker_summary(p.jokers)
        )
        txt_append(line .. "\n")
    end)
    if not ok then
        log("failed to format the txt line: " .. tostring(err), "error")
    end
end

--------------------------------------------------------------
-- Envio
--------------------------------------------------------------

local https
do
    local ok, mod_https = pcall(require, "SMODS.https")
    if ok then https = mod_https end
    if not https then
        local ok2, native = pcall(require, "https")
        if ok2 then https = native end
    end
end

--------------------------------------------------------------
-- Estado de la pestana de configuracion
--------------------------------------------------------------

--- Lo que se lee bajo los controles. Nunca vacio: un G.UIT.T sin texto se
--- queda sin ancho y el nodo desaparece.
local SEED_UI = { status = "Run Tracker is ready", code = "" }

--- Lo que se escribe en el cuadro de los cuadernos, y la linea que dice en
--- que se esta grabando ahora mismo.
local EXTRA_UI = { name = "", list = "" }

--- Repinta la linea de estado. Es texto dinamico (dyn_txt), asi que cambiarlo
--- aqui se ve sin tener que rehacer la pestana.
local function refresh_extra_list()
    local open = extra_logs()
    if #open == 0 then
        EXTRA_UI.list = "Recording to the main log only"
    else
        EXTRA_UI.list = "Also recording to: " .. table.concat(open, ", ")
    end
end

G.FUNCS = G.FUNCS or {}

--- Abrir un cuaderno. El nombre sale del cuadro de texto; si esta vacio o no
--- queda nada despues de limpiarlo, se dice y no se toca nada.
G.FUNCS.runtrk_extra_start = function()
    local label = clean_label(EXTRA_UI.name)
    if not label then
        SEED_UI.status = "Type a name first"
        return
    end

    local open = extra_logs()
    for _, v in ipairs(open) do
        if v:lower() == label:lower() then
            SEED_UI.status = label .. " is already open"
            return
        end
    end
    if #open >= MAX_EXTRA_LOGS then
        SEED_UI.status = "Too many open (max " .. MAX_EXTRA_LOGS .. ")"
        return
    end

    open[#open + 1] = label
    UI.extra_logs = open
    pcall(SMODS.save_mod_config, MOD)
    refresh_extra_list()
    EXTRA_UI.name = ""
    -- El fichero no se crea aqui: nace con la primera partida que acabes. Asi
    -- abrir un cuaderno y arrepentirse no deja un fichero vacio tirado.
    SEED_UI.status = "Recording to " .. extra_log_file(label)
    log("extra log opened: " .. extra_log_file(label))
end

--- Cerrar un cuaderno. Con uno solo abierto no hace falta escribir nada: se
--- cierra ese. Con varios hay que decir cual, que es la contrapartida de
--- poder tener varios a la vez.
G.FUNCS.runtrk_extra_stop = function()
    local open = extra_logs()
    if #open == 0 then
        SEED_UI.status = "No extra log is open"
        return
    end

    local label = clean_label(EXTRA_UI.name)
    if not label then
        if #open > 1 then
            SEED_UI.status = "Type which one to stop"
            return
        end
        label = open[1]
    end

    local rest, found = {}, nil
    for _, v in ipairs(open) do
        if v:lower() == label:lower() then found = v else rest[#rest + 1] = v end
    end
    if not found then
        SEED_UI.status = label .. " is not open"
        return
    end

    UI.extra_logs = rest
    pcall(SMODS.save_mod_config, MOD)
    refresh_extra_list()
    EXTRA_UI.name = ""
    -- Cerrarlo solo deja de escribir: el fichero se queda donde esta, con
    -- todo lo que llevaba dentro.
    SEED_UI.status = "Stopped " .. found .. " (file kept)"
    log("extra log closed: " .. extra_log_file(found))
end

G.FUNCS.runtrk_copy_code = function()
    local code = try(resolved_user_code, "")
    if code == "" then
        SEED_UI.status = "No user code yet"
        return
    end
    local copied = pcall(love.system.setClipboardText, code)
    SEED_UI.status = copied and (code .. " copied") or code
end

--------------------------------------------------------------
-- Pestana de configuracion (Mods > Run Tracker > Config)
--------------------------------------------------------------

local function txt(str, scale, colour)
    return { n = G.UIT.T, config = {
        text = str, scale = scale or 0.4,
        colour = colour or G.C.UI.TEXT_LIGHT,
    } }
end

local function dyn_txt(tbl, key, scale, colour)
    return { n = G.UIT.T, config = {
        ref_table = tbl, ref_value = key, scale = scale or 0.35,
        colour = colour or G.C.UI.TEXT_INACTIVE,
    } }
end

--- Una fila. Cada elemento va en su propia columna: si se meten sueltos
--- dentro del R, el motor no les reserva ancho y se pisan unos a otros.
--- Es como monta el juego la fila de la seed en button_callbacks.lua.
local function row(nodes, align)
    local cols = {}
    for _, n in ipairs(nodes) do
        cols[#cols + 1] = {
            n = G.UIT.C,
            config = { align = "cm", padding = 0.04 },
            nodes = { n },
        }
    end
    return { n = G.UIT.R, config = { align = align or "cm", padding = 0.04 }, nodes = cols }
end

MOD.config_tab = function()
    local code = try(resolved_user_code, "?")
    local tag  = try(resolved_user_tag, "????")
    SEED_UI.code = code
    -- Al abrir la pestana, que la linea de cuadernos diga la verdad de ahora:
    -- puede haberse abierto uno en otra sesion.
    refresh_extra_list()
    local persona = steam_persona()
    -- El nombre que saldria si dejas el cuadro vacio.
    local auto = (persona or profile_name() or "Anonymous") .. "#" .. tag
    -- Solo el dominio: la URL entera no cabe y lo que importa es a donde va.
    local host = CFG.endpoint ~= ""
        and (CFG.endpoint:match("^https?://([^/]+)") or CFG.endpoint)
        or "nowhere (no endpoint set)"

    return {
        n = G.UIT.ROOT,
        config = { align = "cm", minw = 8, padding = 0.12, r = 0.1, colour = G.C.BLACK },
        nodes = {
            -- Nombre + numero, todo en una linea. El numero es texto suelto,
            -- fuera del cuadro, asi que no hay forma de editarlo.
            row({
                txt("Name  ", 0.35, G.C.UI.TEXT_INACTIVE),
                create_text_input({
                    id          = "runtrk_name",
                    ref_table   = UI,
                    ref_value   = "player_name",
                    w           = 3.6,
                    h           = 0.6,
                    max_length  = 24,
                    prompt_text = persona or "Your name",
                }),
                txt(" #" .. tag, 0.4, G.C.BLUE),
            }),
            -- Si el cuadro esta vacio hay que decir con que nombre vas a
            -- salir, no de donde sale: sin Steam, "your Steam name" no
            -- explica nada y la gente acaba publicando como Anonymous.
            row({ txt(UI.player_name ~= ""
                    and "the leaderboard shows this name"
                    or  ("empty: you appear as " .. auto),
                0.26, G.C.UI.TEXT_INACTIVE) }),

            -- Codigo y su boton, en la misma fila.
            row({
                txt("Code  ", 0.35, G.C.UI.TEXT_INACTIVE),
                txt(code .. "  ", 0.38, G.C.BLUE),
                UIBox_button({
                    label = { "Copy" }, button = "runtrk_copy_code",
                    colour = G.C.GREY, minw = 1.6, minh = 0.45, scale = 0.3,
                }),
            }),

            row({
                create_toggle({
                    label = "Upload my runs",
                    ref_table = UI,
                    ref_value = "upload",
                    label_scale = 0.3,
                    w = 2,
                }),
            }),

            -- Cuadernos. Un cuadro y dos botones: el mismo nombre sirve para
            -- abrir y para cerrar. Se hace asi, y no con una fila por
            -- cuaderno abierto con su boton, porque la pestana se construye
            -- una sola vez al abrirla: anadir y quitar filas obligaria a
            -- rehacerla entera cada vez que pulsas.
            row({ txt("Extra log", 0.3, G.C.UI.TEXT_INACTIVE) }),
            row({
                create_text_input({
                    id          = "runtrk_extra",
                    ref_table   = EXTRA_UI,
                    ref_value   = "name",
                    w           = 3.2,
                    h           = 0.6,
                    max_length  = 40,
                    prompt_text = "Run streak",
                }),
                UIBox_button({
                    label = { "Start" }, button = "runtrk_extra_start",
                    colour = G.C.BLUE, minw = 1.5, minh = 0.5, scale = 0.3,
                }),
                UIBox_button({
                    label = { "Stop" }, button = "runtrk_extra_stop",
                    colour = G.C.GREY, minw = 1.5, minh = 0.5, scale = 0.3,
                }),
            }),
            row({ dyn_txt(EXTRA_UI, "list", 0.26) }),

            -- El estado va en su propia fila: cambia de largo al pulsar el
            -- boton, y al lado de otra cosa la desplazaria cada vez.
            row({ dyn_txt(SEED_UI, "status", 0.28) }),

            row({ txt("Sent to " .. host, 0.24, G.C.UI.TEXT_INACTIVE) }),
            row({ txt("Always saved locally in run_tracker_results.txt",
                0.24, G.C.UI.TEXT_INACTIVE) }),
        },
    }
end

--------------------------------------------------------------
-- Aviso de la primera vez
--------------------------------------------------------------

-- Un mod que sube partidas solo no deberia hacerlo sin avisar. Se enseña una
-- vez, en el menu principal, con el nombre que va a aparecer y donde cambiarlo.
-- Queda anotado en la config, asi que no vuelve a salir.
local function first_run_notice()
    if UI.notice_seen then return end
    if not (G.STATES and G.STATE == G.STATES.MENU) then return end
    if G.OVERLAY_MENU then return end          -- ya hay otra cosa abierta
    if type(G.FUNCS.overlay_menu) ~= "function" then return end
    if type(create_UIBox_generic_options) ~= "function" then return end

    local shown = try(resolved_display_name, "?")
    local where = CFG.endpoint ~= ""
        and (CFG.endpoint:match("^https?://([^/]+)") or CFG.endpoint)
        or "nowhere: no server configured"

    local ok = pcall(function()
        G.SETTINGS.paused = true
        G.FUNCS.overlay_menu({
            definition = create_UIBox_generic_options({
                back_label = "OK",
                contents = {
                    row({ txt("Run Tracker is recording your runs", 0.5) }),
                    row({ txt("and uploading them to " .. where,
                        0.32, G.C.UI.TEXT_INACTIVE) }),
                    row({ txt(" ", 0.25) }),
                    row({ txt("You appear as", 0.35, G.C.UI.TEXT_INACTIVE) }),
                    row({ txt(shown, 0.6, G.C.BLUE) }),
                    row({ txt(" ", 0.25) }),
                    row({ txt("Change that name, or turn uploading off,",
                        0.32, G.C.UI.TEXT_INACTIVE) }),
                    row({ txt("in  Mods > Tracker > Config",
                        0.32, G.C.UI.TEXT_INACTIVE) }),
                },
            }),
        })
    end)

    -- Solo se da por visto si de verdad se ha llegado a enseñar.
    if ok then
        UI.notice_seen = true
        pcall(SMODS.save_mod_config, MOD)
        log("first-run notice shown (" .. shown .. ")")
    else
        log("could not show the first-run notice", "error")
    end
end

--------------------------------------------------------------

--- on_done(enviada, info, codigo). El codigo llega tal cual para poder
--- distinguir "vuelve a intentarlo" de "esto no se va a arreglar solo".
local function post(body, on_done)
    if not CFG.enabled or CFG.endpoint == "" then
        return on_done(false, "disabled or no endpoint", nil)
    end
    -- Interruptor de la pestana de config. Se comprueba aqui y no en report()
    -- para que apagarlo tampoco reintente lo que quedo pendiente.
    if UI.upload == false then
        return on_done(false, "uploads turned off in the mod config", 0)
    end
    if not https then
        return on_done(false, "https module not available", nil)
    end

    local headers = { ["Content-Type"] = "application/json" }
    -- El token es opcional: el servidor publico no lo pide. Solo se manda si
    -- lo has rellenado, para instalaciones privadas que si lo exijan.
    if type(CFG.token) == "string" and CFG.token ~= "" then
        headers["Authorization"] = "Bearer " .. CFG.token
    end
    local opts = { method = "POST", headers = headers, data = body }

    local ok = pcall(function()
        if https.asyncRequest then
            https.asyncRequest(CFG.endpoint, opts, function(code, res_body)
                local good = type(code) == "number" and code >= 200 and code < 300
                pcall(on_done, good, tostring(code) .. " " .. tostring(res_body), code)
            end)
        else
            -- fallback sincrono (bloquea un instante, solo si no hay async)
            local code, res_body = https.request(CFG.endpoint, opts)
            local good = type(code) == "number" and code >= 200 and code < 300
            pcall(on_done, good, tostring(code) .. " " .. tostring(res_body), code)
        end
    end)
    if not ok then on_done(false, "request threw an exception", nil) end
end

--- Merece la pena reintentar?
--- Un 429 (demasiadas peticiones) o un 5xx se arreglan esperando. Un 400 o un
--- 401 no: reencolarlos solo llena el fichero de pendientes y machaca el
--- servidor en cada arranque.
local function worth_retrying(code)
    if code == 0 then return false end               -- apagado a proposito
    if type(code) ~= "number" then return true end   -- fallo de red
    if code == 408 or code == 429 then return true end
    if code >= 500 then return true end
    if code >= 400 then return false end
    return true
end

local function report(result)
    -- Partidas con jokers de otros mods: no se guardan ni se envian.
    if CFG.only_vanilla_jokers then
        pcall(scan_jokers_for_mods)
        if modded_joker_seen then
            log("run ignored: uses a joker outside the 150 base ones (" ..
                modded_joker_seen .. ")")
            if CFG.write_txt then
                pcall(function()
                    ensure_header()
                    txt_append(string.format(
                        "# %s | run ignored: non-base joker (%s)\n",
                        os.date("%Y-%m-%d %H:%M:%S"), modded_joker_seen))
                end)
            end
            return
        end
    end

    local ok, payload = pcall(build_payload, result)
    if not ok or not payload then
        log("could not read the run data", "error")
        return
    end

    write_txt(payload)
    log("result written to " .. tostring(save_path(TXT_FILE) or TXT_FILE))

    local ok2, body = pcall(encode, payload)
    if not ok2 or not body then
        log("could not serialize the run", "error")
        return
    end

    if CFG.always_log_local then
        append_file(LOG_FILE, body)
        -- Y una copia en cada cuaderno abierto. La misma linea exacta, para
        -- que cualquiera de los ficheros se pueda cargar en la web igual que
        -- el general.
        local cuadernos = extra_logs()
        for _, label in ipairs(cuadernos) do
            append_file(extra_log_file(label), body)
        end
        if #cuadernos > 0 then
            log("also written to: " .. table.concat(cuadernos, ", "))
        end
    end
    log("run finished: " .. result .. " -> " .. body, "debug")

    -- Mazo de otro mod: queda guardado arriba, pero no se sube.
    if CFG.only_vanilla_decks and not deck_is_vanilla() then
        log("not uploaded: deck '" .. tostring(deck_key() or "?") ..
            "' is not from the base game. The run is still in " ..
            TXT_FILE .. " and " .. LOG_FILE)
        return
    end

    -- Modo local: sin endpoint no hay nada que enviar ni que encolar.
    if not CFG.enabled or CFG.endpoint == "" then
        log("NO ENDPOINT: the run was only saved to " .. TXT_FILE ..
            " (the site will not see it). Set endpoint in settings.lua.")
        return
    end

    post(body, function(sent, info, code)
        if sent then
            log("sent successfully (" .. tostring(info) .. ")")
        elseif code == 0 then
            -- No es un fallo: el jugador ha apagado las subidas.
            log("uploads are off; run saved only in " .. TXT_FILE)
        elseif worth_retrying(code) then
            log("send failed (" .. tostring(info) .. "), stored as pending")
            queue_pending(body)
        else
            -- 400, 401, 403... el servidor ha entendido la peticion y la ha
            -- rechazado. Reintentarla en cada arranque no la va a arreglar.
            log("run rejected by the server (" .. tostring(info) ..
                "), not queued. It stays in " .. TXT_FILE, "error")
        end
    end)
end

--- Se reintenta de una en una, no todas de golpe: un servidor con limite de
--- frecuencia contestaria 429 a la rafaga entera y volveriamos a encolarlas.
local function retry_pending()
    if not (CFG.enabled and CFG.retry_pending_on_boot) then return end
    if CFG.endpoint == "" or not https then return end
    local lines = read_lines(PENDING_FILE)
    if #lines == 0 then return end

    pcall(love.filesystem.remove, PENDING_FILE)
    log("retrying " .. #lines .. " pending runs")

    local i = 0
    local function next_one()
        i = i + 1
        local line = lines[i]
        if not line then return end
        post(line, function(sent, _, code)
            if not sent then
                if worth_retrying(code) then append_file(PENDING_FILE, line) end
                -- Si el servidor esta limitando, se deja el resto para el
                -- proximo arranque en vez de insistir.
                if code == 429 then
                    for j = i + 1, #lines do append_file(PENDING_FILE, lines[j]) end
                    log("server is rate limiting; the rest stays for next boot")
                    return
                end
            end
            next_one()
        end)
    end
    next_one()
end

--------------------------------------------------------------
-- Hooks
--------------------------------------------------------------

local reported = false

--- Nombre legible de un estado, para el log de diagnostico.
local function state_name(st)
    if not G.STATES then return tostring(st) end
    for name, value in pairs(G.STATES) do
        if value == st then return name end
    end
    return tostring(st)
end

--- Solo consideramos que hay una run real si existe una seed.
local function run_active()
    return G.GAME and G.GAME.pseudorandom and G.GAME.pseudorandom.seed and true or false
end

local function finish(result, via)
    if reported or not run_active() then return end
    reported = true
    log("end of run detected via " .. via .. " -> " .. result)
    report(result)
end

-- 1) Inicio / carga de partida: reinicia el flag.
--    Si cargas un save ya ganado (modo infinito) no se vuelve a reportar.
-- 0) Lo que cada joker aporta de verdad. Se envuelve Card:calculate_joker y se
--    guarda el maximo de cada tipo de efecto: asi los jokers cuyo valor depende
--    de la mano jugada (Supernova y compania) quedan con su cifra mas alta.
if CFG.track_joker_values and type(Card) == "table"
   and type(Card.calculate_joker) == "function" then
    local calc_ref = Card.calculate_joker
    function Card:calculate_joker(context)
        local a, b, c = calc_ref(self, context)
        if type(a) == "table" then pcall(record_effect, self, a) end
        return a, b, c
    end
end

-- 0b) Deteccion de jokers de otros mods. add_to_deck() salta cada vez que un
--     joker entra en la mano, asi que tambien pilla los que compras y vendes
--     antes de que termine la partida.
if type(Card) == "table" and type(Card.add_to_deck) == "function" then
    local add_to_deck_ref = Card.add_to_deck
    function Card:add_to_deck(from_debuff)
        pcall(check_vanilla, self.config and self.config.center)
        return add_to_deck_ref(self, from_debuff)
    end
end

-- 0c) Contadores de dinero.
if CFG.track_money then
    -- Casi nada se cobra en el momento. El juego encola el trabajo con
    -- G.E_MANAGER:add_event(Event({func = ...})) y ese func corre frames
    -- despues, cuando la marca de contexto ya se restauro. Entonces el pago
    -- llegaba a ease_dollars sin dueño y se adivinaba por el fichero, que es
    -- justo donde fallaba:
    --
    --   * Faceless Joker encola su ease_dollars (card.lua:3305), asi que el
    --     cobro caia en card.lua y salia como "consumables".
    --   * Comprar en la tienda mete TODA la compra dentro de un evento
    --     (button_callbacks.lua:2453) y el ease_dollars(-coste) esta ahi
    --     dentro (:2510). button_callbacks.lua no estaba en la lista, asi que
    --     el gasto entero salia como "other".
    --
    -- La marca se pone al CREAR el evento, que es cuando todavia se sabe
    -- quien lo pidio, y se repone mientras corre su func. Se envuelve Event
    -- y no EventManager:add_event porque el evento se construye antes de
    -- encolarse, y asi tambien quedan cubiertos los que se guardan para
    -- despues. Solo se envuelve si hay algo que recordar: lo demas pasa de
    -- largo, que esto se llama miles de veces por partida.
    if type(Event) == "table" and type(Event.init) == "function" then
        local ev_init = Event.init
        function Event:init(config, ...)
            ev_init(self, config, ...)
            local ctx, spend = money_ctx, money_ctx_spend
            if (ctx or spend) and type(self.func) == "function" then
                local fn = self.func
                self.func = function(...)
                    -- Se guarda y se repone en vez de limpiar: un evento
                    -- puede crear otro, y el de fuera tiene que recuperar
                    -- la suya al volver.
                    local prev, prev_spend = money_ctx, money_ctx_spend
                    money_ctx, money_ctx_spend = ctx, spend
                    -- pcall para que un fallo del juego no deje la marca
                    -- puesta y contamine todo lo que venga detras. El error
                    -- se vuelve a lanzar tal cual: aqui no se tapa nada.
                    local ok, a, b, c = pcall(fn, ...)
                    money_ctx, money_ctx_spend = prev, prev_spend
                    if not ok then error(a, 0) end
                    return a, b, c
                end
            end
        end
    end

    -- Total real de entradas y salidas: por aqui pasa todo.
    if type(_G.ease_dollars) == "function" then
        local ease_ref = _G.ease_dollars
        _G.ease_dollars = function(mod, ...)
            -- Fuera del pcall a proposito: caller_category cuenta niveles de
            -- pila y meterla dentro de otra funcion los desplazaria.
            local from_source = (not money_ctx) and caller_category() or nil
            pcall(function()
                if type(mod) == "number" and mod == mod then
                    local m = mny(); if not m then return end
                    if mod > 0 then
                        m.earned = m.earned + mod
                        local ctx = money_ctx or from_source
                        if ctx then money_add("from", ctx, mod) end
                    elseif mod < 0 then
                        m.spent = m.spent - mod
                        local ctx = money_ctx_spend or money_ctx or from_source
                        if ctx then money_add("spent_on", ctx, -mod) end
                    end
                end
            end)
            return ease_ref(mod, ...)
        end
    end

    -- El desglose del cobro de fin de ronda, con las categorias del juego.
    if type(_G.add_round_eval_row) == "function" then
        local row_ref = _G.add_round_eval_row
        _G.add_round_eval_row = function(config, ...)
            pcall(function()
                local c = config or {}
                local name = c.name
                if type(name) == "string" and name ~= "bottom" and c.dollars then
                    -- blind1, blind2... son la misma categoria.
                    local cat = name:gsub("%d+$", "")
                    -- La fila 'joker' sale de calculate_dollar_bonus sobre
                    -- G.jokers, G.consumeables y G.vouchers. Si alguna vez
                    -- llega algo que no es un joker, se separa igual.
                    if cat == "joker" and c.card and c.card.ability
                       and c.card.ability.set ~= "Joker" then
                        cat = "other_cards"
                    end
                    money_add("from", cat, c.dollars)
                end
            end)
            return row_ref(config, ...)
        end
    end

    -- Compras, rerolls y ventas.
    if type(G.FUNCS.buy_from_shop) == "function" then
        local buy_ref = G.FUNCS.buy_from_shop
        -- Solo marca el contexto. Contar aqui el coste ademas de dejarlo pasar
        -- por ease_dollars duplicaba las compras que ya tienen su propia via:
        -- un paquete pasa por aqui Y por Card:open, que tambien descuenta.
        G.FUNCS.buy_from_shop = function(...)
            local prev = money_ctx_spend
            money_ctx_spend = "shop"
            local a, b, c = buy_ref(...)
            money_ctx_spend = prev
            return a, b, c
        end
    end

    if type(G.FUNCS.reroll_shop) == "function" then
        local reroll_ref = G.FUNCS.reroll_shop
        G.FUNCS.reroll_shop = function(...)
            -- El numero de rerolls si se cuenta aqui: es un recuento, no
            -- dinero. El importe lo pone ease_dollars, que ademas acierta con
            -- los rerolls gratis (Chaos the Clown, D6 Tag): ahi no se cobra
            -- nada y leer reroll_cost habria sumado igual.
            pcall(function()
                local m = mny(); if m then m.rerolls = m.rerolls + 1 end
            end)
            local prev = money_ctx_spend
            money_ctx_spend = "rerolls"
            local a, b, c = reroll_ref(...)
            money_ctx_spend = prev
            return a, b, c
        end
    end

    -- Cambiar el boss con Director's Cut o Retcon cuesta $10 y se paga desde
    -- button_callbacks.lua, que no es de nadie: sin esto el gasto salia en
    -- "other". Va aparte de "rerolls", que son los de la tienda: no se paga
    -- en el mismo sitio ni por lo mismo. El juego no cobra si el cambio lo
    -- regala el Boss Tag (G.from_boss_tag), y como el importe lo pone
    -- ease_dollars, esos salen a 0 solos.
    if type(G.FUNCS.reroll_boss) == "function" then
        local rb_ref = G.FUNCS.reroll_boss
        G.FUNCS.reroll_boss = function(...)
            local prev = money_ctx_spend
            money_ctx_spend = "boss_reroll"
            local a, b, c = rb_ref(...)
            money_ctx_spend = prev
            return a, b, c
        end
    end

    -- Desafios que cobran por descartar (G.GAME.modifiers.discard_cost). El
    -- cobro es sincrono dentro de discard_cards_from_highlighted
    -- (state_events.lua:450), asi que basta con marcar la llamada.
    if type(G.FUNCS.discard_cards_from_highlighted) == "function" then
        local disc_ref = G.FUNCS.discard_cards_from_highlighted
        G.FUNCS.discard_cards_from_highlighted = function(...)
            local prev = money_ctx_spend
            money_ctx_spend = "discard_cost"
            local r = disc_ref(...)
            money_ctx_spend = prev
            return r
        end
    end

    -- Jokers que cobran llamando a ease_dollars desde dentro de su calculo.
    if type(Card) == "table" and type(Card.calculate_joker) == "function" then
        local cj_ref = Card.calculate_joker
        function Card:calculate_joker(...)
            -- Se guarda y se restaura en vez de poner a nil: Blueprint hace
            -- que esta funcion se llame dentro de si misma.
            local prev = money_ctx
            money_ctx = "jokers_inplay"
            local a, b, c = cj_ref(self, ...)
            money_ctx = prev
            return a, b, c
        end
    end

    -- Cartas con mejora de oro que tienes en mano al acabar la ronda. NO van
    -- por el cobro de fin de ronda: las dos listas que recorre evaluate_round
    -- son jokers (G.jokers, consumeables, vouchers) y objetos individuales
    -- (mazo, blind, desafio, stake, mods). Una carta de la mano no esta en
    -- ninguna.
    --
    -- Se engancha get_end_of_round_effect y NO get_h_dollars: ese getter lo
    -- llama tambien generate_UIBox_ability_table (card.lua:906), o sea la
    -- descripcion de la carta, asi que contaba $3 cada vez que se dibujaba
    -- un tooltip. get_end_of_round_effect solo lo llama el recuento de fin
    -- de ronda (common_events.lua:691).
    if type(Card) == "table" and type(Card.get_end_of_round_effect) == "function" then
        local eor_ref = Card.get_end_of_round_effect
        function Card:get_end_of_round_effect(...)
            local ret = eor_ref(self, ...)
            pcall(function()
                if type(ret) == "table" and type(ret.h_dollars) == "number"
                   and ret.h_dollars > 0 then
                    money_add("from", "gold_cards", ret.h_dollars)
                end
            end)
            return ret
        end
    end

    -- Bosses que te quitan dinero. The Ox lo pone a cero al jugar tu mano mas
    -- usada, con ease_dollars(-G.GAME.dollars) desde Blind:debuff_hand
    -- (blind.lua:605). Se marca la funcion entera y no solo The Ox, para que
    -- cualquier otro boss que cobre caiga tambien aqui.
    if type(Blind) == "table" and type(Blind.debuff_hand) == "function" then
        local debuff_ref = Blind.debuff_hand
        function Blind:debuff_hand(...)
            local prev = money_ctx_spend
            money_ctx_spend = "boss"
            local a, b, c = debuff_ref(self, ...)
            money_ctx_spend = prev
            return a, b, c
        end
    end

    -- Comprar un paquete (Card:open) y canjear un vale (Card:redeem) tienen
    -- su propio ease_dollars(-self.cost) y no pasan por buy_from_shop.
    for _, fn in ipairs({ "open", "redeem" }) do
        if type(Card) == "table" and type(Card[fn]) == "function" then
            local ref = Card[fn]
            Card[fn] = function(self, ...)
                local prev = money_ctx_spend
                money_ctx_spend = "shop"
                local a, b, c = ref(self, ...)
                money_ctx_spend = prev
                return a, b, c
            end
        end
    end

    -- Tags que pagan al usarlos y no en el cobro de fin de ronda: Speed,
    -- Garbage, Handy y Economy llaman a ease_dollars desde Tag:apply_to_run
    -- (tag.lua:175-205). El Investment Tag si va por el cash out, asi que
    -- este hook no lo toca.
    if type(Tag) == "table" and type(Tag.apply_to_run) == "function" then
        local tag_ref = Tag.apply_to_run
        function Tag:apply_to_run(...)
            local prev = money_ctx
            money_ctx = "tag"
            local r = tag_ref(self, ...)
            money_ctx = prev
            return r
        end
    end

    -- Tarots y espectrales que dan dinero (Hermit, Temperance, Immolate).
    if type(Card) == "table" and type(Card.use_consumeable) == "function" then
        local uc_ref = Card.use_consumeable
        function Card:use_consumeable(...)
            local prev = money_ctx
            money_ctx = "consumables"
            local r = uc_ref(self, ...)
            money_ctx = prev
            return r
        end
    end

    -- Lo que paga una carta jugada: el sello dorado son $3, Lucky Card tira
    -- el dado, y p_dollars es el resto. get_p_dollars consume numeros
    -- aleatorios (la tirada de Lucky Card), asi que se llama UNA sola vez y
    -- se reparte su resultado; volver a llamarla cambiaria la partida.
    if type(Card) == "table" and type(Card.get_p_dollars) == "function" then
        local pd_ref = Card.get_p_dollars
        function Card:get_p_dollars(...)
            local ret = pd_ref(self, ...)
            pcall(function()
                if type(ret) ~= "number" or ret <= 0 then return end
                local rest = ret
                -- Misma condicion que usa el juego para el sello (card.lua).
                if self.seal == "Gold" and not self.ability.extra_enhancement then
                    money_add("from", "gold_seals", 3)
                    rest = rest - 3
                end
                if rest > 0 then
                    money_add("from",
                        self.lucky_trigger and "lucky_cards" or "cards", rest)
                end
            end)
            return ret
        end
    end

    -- El alquiler de los jokers con sticker rental. Card:calculate_rental()
    -- es una funcion dedicada (card.lua:2672) que cobra G.GAME.rental_rate
    -- por cada uno al acabar la ronda, asi que la atribucion es exacta.
    -- El alquiler tenia el mismo problema en potencia: paga con ease_dollars
    -- desde card.lua, asi que sumarlo aqui lo habria duplicado en Gold Stake.
    -- Tambien va por contexto.
    if type(Card) == "table" and type(Card.calculate_rental) == "function" then
        local rental_ref = Card.calculate_rental
        function Card:calculate_rental(...)
            local prev = money_ctx_spend
            money_ctx_spend = "rentals"
            local a, b, c = rental_ref(self, ...)
            money_ctx_spend = prev
            return a, b, c
        end
    end

    -- Vender: se marca el contexto y NO se suma aqui. Card:sell_card paga con
    -- ease_dollars desde card.lua, asi que sumarlo tambien en este hook lo
    -- contaba dos veces (y el fallback por fichero lo etiquetaba ademas como
    -- consumible). Una sola fuente de verdad: ease_dollars.
    if type(G.FUNCS.sell_card) == "function" then
        local sell_ref = G.FUNCS.sell_card
        G.FUNCS.sell_card = function(...)
            local prev = money_ctx
            money_ctx = "sales"
            local a, b, c = sell_ref(...)
            money_ctx = prev
            return a, b, c
        end
    end
end

-- NO USAR G.GAME.won PARA DECIDIR EL RESULTADO.
-- Balatro tiene un bug en end_round(): al terminar la ronda de la ciega final
-- pone won = true antes de comprobar si la has superado, asi que tambien se
-- activa cuando pierdes contra el jefe del ante 8.
--
--     if G.GAME.round_resets.ante == G.GAME.win_ante
--        and G.GAME.blind:get_type() == 'Boss' then
--         game_won = true
--         G.GAME.won = true          -- <-- antes del if game_over
--     end
--     if game_over then
--         G.STATE = G.STATES.GAME_OVER
--
-- Las senales fiables son otras:
--   * Derrota: entrar en G.STATES.GAME_OVER. El juego solo llega ahi cuando la
--     puntuacion no alcanza (end_round) o cuando te quedas sin cartas que robar.
--     Las dos son derrotas.
--   * Victoria: win_game(), que solo se llama en la rama en la que SI superaste
--     la ciega. G.GAME.win_notified se pone justo ahi y sirve igual.

local start_run_ref = Game.start_run
function Game:start_run(args)
    local ret = start_run_ref(self, args)
    joker_peaks = {}
    modded_joker_seen = nil
    pcall(scan_jokers_for_mods)   -- partidas cargadas de un guardado
    -- Al cargar una partida ya ganada (modo infinito) no se vuelve a reportar.
    reported = (G.GAME and (G.GAME.win_notified or G.GAME.won)) and true or false
    log("start_run (reported=" .. tostring(reported) .. ")", "debug")
    return ret
end

-- 2) Vigilante de estado. Detector principal de la DERROTA.
local last_state = nil
local update_ref = Game.update
function Game:update(dt)
    local ret = update_ref(self, dt)
    pcall(function()
        -- Antes que nada, la pasada por la fila de jokers: es lo unico que hay
        -- que hacer todos los frames, y hacerla aqui la deja tambien cubierta
        -- por este pcall.
        sweep_jokers()
        if G.STATE ~= last_state then
            last_state = G.STATE
            log("state -> " .. state_name(G.STATE), "debug")
            if CFG.only_vanilla_jokers then scan_jokers_for_mods() end
            first_run_notice()
            if G.STATES and G.STATE == G.STATES.GAME_OVER then
                -- Entrar en GAME_OVER siempre es perder, digan lo que digan
                -- G.GAME.won o el ante en el que estes.
                finish("loss", "cambio de estado a GAME_OVER")
            end
        end
        -- Victoria: win_notified solo se activa en la rama de ciega superada.
        if not reported and G.GAME and G.GAME.win_notified then
            finish("win", "G.GAME.win_notified")
        end
    end)
    return ret
end

-- 3) Red de seguridad para la derrota: primer frame del estado GAME_OVER.
if type(Game.update_game_over) == "function" then
    local game_over_ref = Game.update_game_over
    function Game:update_game_over(dt)
        if not reported and not G.STATE_COMPLETE then
            finish("loss", "update_game_over")
        end
        return game_over_ref(self, dt)
    end
end

-- 4) Victoria: win_game() es global y el juego solo la llama tras superar la
--    ciega final. Es la senal mas directa que hay.
if type(_G.win_game) == "function" then
    local win_game_ref = _G.win_game
    _G.win_game = function(...)
        local a, b, c = win_game_ref(...)
        pcall(finish, "win", "win_game()")
        return a, b, c
    end
end

--------------------------------------------------------------

local function boot_diagnostics()
    local save_dir = try(function() return love.filesystem.getSaveDirectory() end, "?")
    local lines = {}
    local function add(l) lines[#lines + 1] = l end

    add("")
    add("# ---------------------------------------------------------------")
    add("# Run Tracker " .. tostring(MOD and MOD.version or "?") ..
        " loaded on " .. os.date("%Y-%m-%d %H:%M:%S"))
    add("#   save folder          : " .. tostring(save_dir))
    add("#   RESULTS FILE         : " .. tostring(save_path(TXT_FILE)))
    add("#   settings.lua loaded  : " .. (SETTINGS_LOADED and "yes" or "NO (using defaults)"))
    add("#   player               : " .. tostring(try(resolved_display_name, "?")))
    add("#   user code            : " .. tostring(try(resolved_user_code, "?")) ..
        " (" .. tostring(UI.user_code_source ~= "" and UI.user_code_source or "?") .. ")")
    add("#   identity file        : " .. tostring(identity_path() or "?"))
    do
        local open = extra_logs()
        add("#   extra logs           : " ..
            (#open > 0 and table.concat(open, ", ") or "none"))
    end
    add("#   endpoint             : " .. (CFG.endpoint ~= "" and CFG.endpoint or "NOT CONFIGURED"))
    if ENDPOINT_WARNING then
        add("#   WARNING              : " .. ENDPOINT_WARNING)
    end
    if CFG.endpoint == "" then
        add("#   WARNING              : with no endpoint, runs only stay in this")
        add("#                          file; the site gets nothing. Fill in")
        add("#                          endpoint and token in settings.lua.")
    end
    add("#   uploads              : " .. (UI.upload ~= false and "on" or "OFF (mod config)"))
    add("#   base jokers only     : " .. (CFG.only_vanilla_jokers and "yes" or "no"))
    add("#   https module         : " .. (https and "available" or "not available"))
    add("#   Steam (luasteam)     : " .. (G.STEAM and "available" or "not available"))
    add("#   Game.update_game_over: " .. type(Game.update_game_over))
    add("#   G.STATES.GAME_OVER   : " .. tostring(G.STATES and G.STATES.GAME_OVER or "missing"))
    add("# ---------------------------------------------------------------")

    for _, l in ipairs(lines) do log((l:gsub("^# ", ""))) end
    if CFG.write_txt then
        ensure_header()
        txt_append(table.concat(lines, "\n") .. "\n")
    end
end

if CFG.enabled then
    boot_diagnostics()
    retry_pending()
else
    log("loaded but disabled in settings.lua")
end
