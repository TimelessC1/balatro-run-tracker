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

local function enc_number(n)
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n % 1 == 0 and math.abs(n) < 9007199254740992 then
        return string.format("%d", n)
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

local function fmt_num(v)
    if v % 1 == 0 then return string.format("%d", v) end
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
    if math.abs(v) < 1e15 and v % 1 == 0 then return string.format("%d", v) end
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
-- Seeds pendientes (boton "copiar seed no ganada")
--------------------------------------------------------------

--- La URL se deriva del endpoint: si envias a .../run o a .../api/run, las
--- seeds se piden a .../api/seeds/unbeaten. Asi solo hay un campo que
--- configurar. Va bajo /api/ porque en el Worker todo lo que no empieza por
--- ahi lo sirve el binding de assets, y contestaria con la pagina web.
local function seed_url()
    local ep = CFG.endpoint
    if type(ep) ~= "string" or ep == "" then return nil end
    local base = ep:gsub("%s+$", ""):gsub("/+$", "")
                   :gsub("/api/run$", ""):gsub("/run$", "")
    return base .. "/api/seeds/unbeaten"
end

--- Estado que pinta la pestana de config. Nunca vacio: un G.UIT.T sin texto
--- se queda sin ancho y el nodo desaparece.
local SEED_UI = { status = "Press the button for a seed", code = "" }

--- Acepta {"seed":"8FN3D2KL"} o la seed sola en texto plano.
local function extract_seed(body)
    if type(body) ~= "string" then return nil end
    -- Si la ruta no existe, el Worker devuelve la pagina web entera. No se
    -- busca dentro de un HTML: cualquier "seed":"..." suelto en su javascript
    -- pasaria por una seed de verdad.
    if body:match("^%s*<") then return nil end
    local s = body:match('"seed"%s*:%s*"([^"]+)"')
    if not s then s = body:match("^%s*([%w]+)%s*$") end
    if s and #s >= 4 and #s <= 12 then return s:upper() end
    return nil
end

local function fetch_unbeaten_seed()
    local url = seed_url()
    if not url then
        SEED_UI.status = "No endpoint configured"
        return
    end
    if not https then
        SEED_UI.status = "https module not available"
        return
    end

    SEED_UI.status = "Looking..."
    local headers = {}
    if CFG.token ~= "" then headers["Authorization"] = "Bearer " .. CFG.token end
    -- Se manda el codigo para que el servidor pueda saltarse las que tu ya
    -- has ganado, no solo las que no ha ganado nadie.
    local full = url .. "?user_code=" .. tostring(try(resolved_user_code, ""))
    local opts = { method = "GET", headers = headers }

    local function done(code, body)
        if not (type(code) == "number" and code >= 200 and code < 300) then
            SEED_UI.status = "Error " .. tostring(code)
            return
        end
        local seed = extract_seed(body)
        if not seed then
            SEED_UI.status = "No unbeaten seeds left"
            return
        end
        local copied = pcall(love.system.setClipboardText, seed)
        SEED_UI.status = copied and (seed .. " copied")
                                 or (seed .. " (clipboard failed)")
        log("unbeaten seed: " .. seed)
    end

    local ok = pcall(function()
        if https.asyncRequest then
            https.asyncRequest(full, opts, function(c, b) pcall(done, c, b) end)
        else
            local c, b = https.request(full, opts)
            done(c, b)
        end
    end)
    if not ok then SEED_UI.status = "Request failed" end
end

G.FUNCS = G.FUNCS or {}

G.FUNCS.runtrk_copy_seed = function()
    pcall(fetch_unbeaten_seed)
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

            row({
                UIBox_button({
                    label = { "Copy unbeaten seed" }, button = "runtrk_copy_seed",
                    colour = G.C.BLUE, minw = 3.4, minh = 0.55, scale = 0.32,
                }),
            }),
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

    if CFG.always_log_local then append_file(LOG_FILE, body) end
    log("run finished: " .. result .. " -> " .. body, "debug")

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
    add("#   unbeaten seeds at    : " .. tostring(seed_url() or "no endpoint"))
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
