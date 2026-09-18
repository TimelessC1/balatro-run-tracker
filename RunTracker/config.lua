-- ============================================================
--  Run Tracker - valores por defecto de la config del mod
--
--  Esto es solo la plantilla. Lo que edites en el juego
--  (Mods > Run Tracker > Config) lo guarda Steamodded en
--  config/RunTracker.jkr y manda sobre estos valores.
--
--  El endpoint, el token y el resto de interruptores siguen
--  en settings.lua.
-- ============================================================

return {
    -- Nombre con el que apareces en la web.
    -- Vacio = se usa tu nombre de Steam.
    player_name = "",

    -- Codigo que te distingue de otro jugador que se llame igual.
    -- Se genera solo la primera vez a partir de tu cuenta de Steam
    -- y ya no vuelve a cambiar. No lo toques salvo que sepas por que.
    user_code = "",

    -- "steam" si salio de tu SteamID, "random" si se sorteo por no
    -- haber Steam disponible.
    user_code_source = "",

    -- Las cuatro cifras que se pegan al nombre ("TimelessC1#0042"). Se sortean
    -- una sola vez. No se puede editar desde el juego.
    user_tag = "",

    -- Subir las partidas al ranking. Activado de fabrica: el mod esta hecho
    -- para funcionar sin configurar nada. Se apaga desde
    -- Mods > Run Tracker > Config, sin tocar ficheros.
    -- Apagado, las partidas se siguen guardando en el txt local.
    upload = true,

    -- Si ya se ha enseñado el aviso de la primera vez. Ponlo en false para
    -- volver a verlo.
    notice_seen = false,
}

-- OJO: la copia buena de user_code y user_tag no es esta, es
-- <carpeta de guardado>/run_tracker_identity.txt. Ese fichero esta fuera
-- de la carpeta del mod, asi que sobrevive a desinstalarlo.
