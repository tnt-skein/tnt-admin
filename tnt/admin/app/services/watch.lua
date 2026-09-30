--- Обход кластера: панель заводит его сама, когда ей дали учётку.
---
--- Снимок кластера панель не снимает — она его показывает, — но снимать
--- его кто-то должен. Обычно это приложение: оно знает, под какой
--- учётной записью ходить к соседям, и заводит обход у себя. На узле,
--- где панель стоит одна — рядом с чужим приложением или вовсе без
--- него, — заводить обход некому, и панель показывает пустой кластер,
--- хотя диагностика рядом установлена.
---
--- Поэтому обход можно поручить самой панели: оператор называет в
--- настройках учётку наблюдателя, и панель на каждом применении
--- конфигурации настраивает обход и запускает его.
---
---     -- config/admin.lua
---     return function(env)
---         return {
---             watch = {
---                 login = env('ADMIN_WATCH_LOGIN', 'health'),
---                 password = env('ADMIN_WATCH_PASSWORD'),
---             },
---         }
---     end
---
--- Без учётки панель обход не заводит: ходить к соседям ей нечем,
--- а молчаливая попытка под чужой учёткой кончилась бы отказами
--- в журнале у каждого узла кластера.
---
--- Права у этой учётки — только вызов зонда (`lua_call` на
--- `cluster_probe`): ни данных, ни удалённого исполнения кода.

local external = require('tnt.external')

local packages = require('tnt.admin.app.support.packages')

local Module = {}

--- Диагностика кластера: пакет, который обходит соседей.
---
--- Подключается по требованию, а не в шапке: панель работает и без него,
--- и на узле, где его нет, спрашивать его незачем.
---@return table|nil
function Module.cluster()
    return packages.of('tnt.cluster')
end

--- Средства снаружи: диагностика кластера.
---
--- Внешней зависимостью, потому что проверки идут без установленного
--- пакета — и с ним: на машине, где стоит то одно, то другое, это
--- не проверить.
local source = external.install(Module, { cluster = Module.cluster })

--- Завела ли обход сама панель.
---
--- Состояние процессное, как и сам обход: он один на узел, и панель
--- в процессе одна. По этому признаку она и снимает за собой только
--- своё — обход соседа переживает её.
local own = false

--- Заводит обход по настройке.
---
--- Обход, уже идущий на этом узле, не трогается: его мог завести сосед
--- по процессу — приложение или вторая панель, — и перенастройка увела бы
--- его на другую учётку молча.
---@param settings table|nil Раздел `watch` настроек панели
---@return string|nil started Слова для журнала; пусто — обход не заводили
function Module.start(settings)
    local given = settings or {}

    if given.login == nil then
        return nil
    end

    local cluster = source().cluster()

    if cluster == nil then
        return nil
    end

    if cluster.status().running then
        return nil
    end

    cluster.configure({
        login = given.login,
        password = given.password,
        interval = given.interval,
        timeout = given.timeout,
        connect_timeout = given.connect_timeout,
    })

    cluster.start()

    own = true

    return ('обход кластера заведён под учёткой %s'):format(given.login)
end

--- Останавливает обход, заведённый панелью.
---
--- Чужой обход не трогается по той же причине, по какой не трогается при
--- заводе: панель, снятая с узла, не должна уносить с собой диагностику
--- соседа.
function Module.stop()
    if not own then
        return
    end

    own = false

    local cluster = source().cluster()

    if cluster ~= nil then
        cluster.stop()
    end
end

return Module
