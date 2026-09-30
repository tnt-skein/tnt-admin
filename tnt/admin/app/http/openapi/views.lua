--- Описание операций, которые читают кластер: узлы, находки, подсказки,
--- возможности, отбор узлов конфигурации и выкладка метрик.
---
--- Часть описания API панели (`tnt.admin.app.http.openapi`): здесь только
--- слова и коды, схемы тел ответов — формы `tnt.admin.app.data.cluster`.

local cluster = require('tnt.admin.app.data.cluster')

--- Параметр отбора списком через запятую.
---
--- Стиль `form` без `explode`: имена идут одним значением через запятую,
--- как их разбирает `tnt.admin.app.http.handlers.instances`.
---@param name string
---@param description string
---@return table
local function listed(name, description)
    return {
        name = name,
        ['in'] = 'query',
        description = description,
        style = 'form',
        explode = false,
        schema = { type = 'array', items = { type = 'string', minLength = 1 } },
    }
end

--- Параметры отбора узлов: группы, репликасеты и имена читаются как
--- «любой из», роли и метки — как «все сразу».
local INSTANCES = {
    listed('groups', 'Любая из групп, через запятую'),
    listed('replicasets', 'Любой из репликасетов, через запятую'),
    listed('instances', 'Любое из имён узлов, через запятую'),
    listed('roles', 'Все перечисленные роли, через запятую'),
    listed(
        'sharding_roles',
        'Все перечисленные роли шардирования, через запятую: router, storage. '
            .. 'Ребалансировщика по конфигурации не найти — его назначает vshard, и такой отбор отвергается'
    ),
    {
        name = 'labels',
        ['in'] = 'query',
        description = 'Все перечисленные метки, по одной — labels[zone]=spb',
        style = 'deepObject',
        explode = true,
        schema = { type = 'object', additionalProperties = { type = 'string' } },
    },
}

---@param words TntAdminApiWords
---@return table<string, table>
return function(words)
    return {
        cluster = {
            summary = 'Узлы и репликасеты',
            responses = {
                [200] = { description = 'Представление кластера', schema = cluster.Cluster },
                [401] = words.unauthenticated,
            },
        },
        instances = {
            summary = 'Узлы, объявленные конфигурацией, по отбору',
            description = [[
Чтение объявленного, а не применённого: узлы не опрашиваются, и живы ли они, говорит
/cluster. Без параметров — все узлы конфигурации, вместе с узлом панели; порядок — по
имени.

Незнакомый параметр, повторённый параметр и пустое имя в списке — отказ: потерянное
условие молча расширило бы ответ, и скрипт, выбирающий узлы для действия, задел бы
лишние.
]],
            parameters = INSTANCES,
            responses = {
                [200] = cluster.ConfigInstances,
                [400] = 'Отбор не разобран или диагностика отказала. Неверные параметры названы в error.fields; '
                    .. 'отказ диагностики — ребалансировщик, незнакомая роль шардирования — '
                    .. 'приходит её словами в error.message',
                [401] = words.unauthenticated,
                [501] = 'Отбор узлов этой панели недоступен: диагностика (tnt-cluster-health) '
                    .. 'не установлена или выключена настройкой',
            },
        },
        issues = {
            summary = 'Находки диагностики',
            responses = { [200] = cluster.Issues, [401] = words.unauthenticated },
        },
        suggestions = {
            summary = 'Что оператору предлагается сделать',
            responses = { [200] = cluster.Suggestions, [401] = words.unauthenticated },
        },
        overview = {
            summary = 'Всё сразу за один обход кластера',
            description = 'Страница обзора спрашивает именно это: узлы, находки и подсказки '
                .. 'собираются по одному снимку, а не тремя обходами подряд.',
            responses = { [200] = cluster.Overview, [401] = words.unauthenticated },
        },
        capabilities = {
            summary = 'Что умеет этот кластер',
            description = 'Панель одна на все кластеры: в одном есть внешний координатор, '
                .. 'в другом выборы ядра, в третьем ни того ни другого. Панель спрашивает, а не догадывается.',
            responses = { [200] = cluster.Capabilities, [401] = words.unauthenticated },
        },
        metrics = {
            summary = 'Состояние кластера числами в формате Prometheus',
            description = 'Вне общего начала путей: это договор со сборщиком, а не часть API панели. '
                .. 'Ходит он по /metrics, ждёт текст, а не JSON, и про версии API ничего не знает. '
                .. 'Отказ при этом — JSON того же вида, что у всей панели: сборщик его не разбирает, '
                .. 'а читает его человек.',
            responses = {
                [200] = {
                    description = 'Выкладка метрик текстом',
                    media = 'text/plain',
                    schema = { type = 'string' },
                },
                [401] = 'Сборщик не назвал себя или назвался не тем',
                [501] = 'Выкладка на этой панели не включена',
            },
        },
    }
end
