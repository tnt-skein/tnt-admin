--- Тесты данных страниц: что узел кладёт в шаблон.
---
--- Страницу рисует шаблонизатор, а собирает её данные этот модуль, и
--- проверять его надо без разметки: отбор узлов, счёт находок и привязка
--- подсказок к узлам — это правила панели, а не вёрстка.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.services.pages')

---@type any
local pages

--- Снимок кластера из двух узлов: один пишет, второй не отвечает.
---@return table
local function snapshot()
    return {
        generation = 3,
        taken_at = 1789041300,
        instances = {
            ['storage-001-a'] = {
                name = 'storage-001-a',
                replicaset_name = 'storage-001',
                advertise = { uri = '10.0.0.7:3301' },
                reachable = true,
                status = 'running',
                ro = false,
                memory = {},
            },
            ['storage-001-b'] = {
                name = 'storage-001-b',
                replicaset_name = 'storage-001',
                advertise = { uri = '10.0.0.8:3301' },
                reachable = false,
                status = 'unreachable',
                ro = true,
                memory = {},
            },
            -- Узел отвечает, но живёт без лидера: беда бывает и у того,
            -- до кого достучались.
            ['alpha'] = {
                name = 'alpha',
                replicaset_name = 'core-001',
                advertise = { uri = '10.0.0.9:3301' },
                reachable = true,
                status = 'orphan',
                ro = true,
                memory = {},
            },
        },
        replicasets = {
            ['storage-001'] = {
                name = 'storage-001',
                instances = { 'storage-001-a', 'storage-001-b' },
                leaders = { 'storage-001-a' },
            },
            ['core-001'] = { name = 'core-001', instances = { 'alpha' } },
        },
    }
end

--- Источники панели: снимок, находки и подсказки.
---@param overrides table|nil
---@return table
local function source(overrides)
    local given = {
        snapshot = snapshot,
        issues = function()
            return {
                { id = 'memory:storage-001-a', rule = 'memory', severity = 'warning', message = 'тесно' },
                { id = 'clock:alpha', rule = 'clock', severity = 'warning', message = 'часы врут' },
                { id = 'reach:storage-001-b', rule = 'reachability', severity = 'critical', message = 'молчит' },
            }
        end,
        suggestions = function()
            return { { action = 'reload_config', targets = { 'storage-001-b' }, message = 'перечитать' } }
        end,

        appointments = function()
            return { ['core-001'] = 'alpha' }
        end,
    }

    for name, value in pairs(overrides or {}) do
        given[name] = value
    end

    return given
end

g.before_each(function()
    pages = helper.load('tnt.admin.app.services.pages')
end)

g.after_each(function()
    helper.unload()
end)

g.test_every_page_knows_the_menu_and_its_own_section = function()
    -- Меню собирается из одного списка: раздел, добавленный в него,
    -- появляется сам, и забыть про него нельзя.
    local shown = pages.overview(source())

    t.assert_equals(shown.section, 'overview')
    t.assert_equals(#shown.sections, #pages.SECTIONS)
    t.assert_equals(shown.sections[1].path, '/')
    t.assert_type(shown.now, 'number')
end

g.test_the_overview_counts_the_critical_findings = function()
    -- Число важных находок видно из меню, не заходя в раздел.
    local shown = pages.overview(source())

    t.assert_equals(shown.critical, 1, 'важная находка одна, а находок больше')
    t.assert_equals(shown.issues_count, 3)
    t.assert_equals(#shown.suggestions, 1)
    t.assert_equals(#shown.cluster.servers, 3)
end

g.test_the_appointment_of_the_coordinator_reaches_the_page = function()
    -- Кого назначили и кто на самом деле пишет — разные вещи, и
    -- расхождение между ними говорит больше любой находки. Назначение
    -- знает координатор, а не снимок: без него страница показала бы
    -- репликасет без назначенного лидера.
    local named = {}

    for _, replicaset in ipairs(pages.cluster(source(), {}).cluster.replicasets) do
        named[replicaset.name] = replicaset.leader
    end

    t.assert_equals(named['core-001'], 'alpha')

    local silent = source()

    -- Координатора на узле нет вовсе: назначать некому.
    silent.appointments = nil

    local without = {}

    for _, replicaset in ipairs(pages.cluster(silent, {}).cluster.replicasets) do
        without[replicaset.name] = replicaset.leader
    end

    t.assert_equals(without['core-001'], nil)
end

g.test_the_cluster_page_knows_its_nodes_by_name_and_who_writes = function()
    -- Карточка репликасета знает только имена своих узлов, а всё
    -- остальное о них лежит общим списком.
    local shown = pages.cluster(source(), {})

    t.assert_equals(shown.total, 3)
    t.assert_equals(shown.filter, 'all')
    t.assert_equals(shown.cluster.by_name['storage-001-b'].reachable, false)
    t.assert_equals(shown.cluster.writers['storage-001-a'], true)
    t.assert_equals(shown.cluster.writers['storage-001-b'], nil)
end

g.test_nodes_are_filtered_by_trouble_and_by_writing = function()
    -- С бедой — и тот, до кого не достучались, и тот, кто отвечает,
    -- но не работает: одного признака мало.
    local troubled = pages.cluster(source(), { filter = 'trouble' })
    local names = {}

    for _, server in ipairs(troubled.servers) do
        table.insert(names, server.name)
    end

    table.sort(names)

    t.assert_equals(names, { 'alpha', 'storage-001-b' })

    -- Пишет тот, кто отвечает и не в режиме только чтения: `alpha`
    -- назначен вести репликасет, но сам пишущим себя не считает.
    local writers = pages.cluster(source(), { filter = 'writers' })

    t.assert_equals(#writers.servers, 1)
    t.assert_equals(writers.servers[1].name, 'storage-001-a')
end

g.test_the_search_looks_at_the_name_the_replicaset_and_the_address = function()
    -- Поиск — это адрес страницы, и ищет он по тому, что видно в списке:
    -- по имени узла, по имени его репликасета и по адресу.
    local by_name = pages.cluster(source(), { search = '001-B' })

    t.assert_equals(#by_name.servers, 1)
    t.assert_equals(by_name.servers[1].name, 'storage-001-b')

    local by_replicaset = pages.cluster(source(), { search = 'core-001' })

    t.assert_equals(#by_replicaset.servers, 1)
    t.assert_equals(by_replicaset.servers[1].name, 'alpha')

    local by_address = pages.cluster(source(), { search = '10.0.0.8' })

    t.assert_equals(#by_address.servers, 1)
    t.assert_equals(by_address.servers[1].name, 'storage-001-b')

    t.assert_equals(#pages.cluster(source(), { search = 'нет такого' }).servers, 0)
end

g.test_the_search_matches_from_the_first_letter_too = function()
    -- Искомое стоит в самом начале строки: поиск, начатый со второго
    -- знака, узел с таким именем потерял бы.
    local found = pages.cluster(source(), { search = 'alpha' })

    t.assert_equals(#found.servers, 1)
    t.assert_equals(found.servers[1].name, 'alpha')
end

g.test_a_node_that_does_not_suit_the_filter_is_answered_with_a_plain_no = function()
    -- Отбор отвечает «нет», а не пустотой: пустота в Lua ложна так же,
    -- но договор у этой проверки — два ответа, да и нет.
    t.assert_equals(pages.suits({ name = 'alpha' }, 'all', 'нет такого'), false)
    t.assert_equals(pages.suits({ name = 'alpha' }, 'all', 'alpha'), true)
end

g.test_findings_are_counted_by_level_and_filtered_by_it = function()
    local shown = pages.issues(source(), { level = 'critical' })

    t.assert_equals(#shown.issues, 3, 'счётчики считаются по всем находкам')
    t.assert_equals(#shown.shown, 1)
    t.assert_equals(shown.shown[1].level, 'critical', 'показаны те, что просили')
    t.assert_equals(shown.counts.critical, 1)
    t.assert_equals(shown.counts.warning, 2)
    t.assert_equals(shown.level, 'critical')

    -- Без отбора — все находки: «все» это не уровень, а его отсутствие.
    t.assert_equals(#pages.issues(source(), {}).shown, 3)
end

g.test_advice_is_tied_to_the_node_it_is_about = function()
    -- Подсказка показывается рядом с находкой о том же узле: искать её
    -- на другой странице дежурному некогда.
    local shown = pages.issues(source(), {})

    t.assert_equals(#shown.advice['storage-001-b'], 1)
    t.assert_equals(shown.advice['storage-001-b'][1].action, 'reload_config')
    t.assert_equals(shown.advice['storage-001-a'], nil)
end

g.test_the_configuration_page_says_plainly_what_is_missing = function()
    -- Конфигурации может не быть вовсе, и она может не прочитаться:
    -- это разные ответы, и оба — слова, а не пустая страница.
    t.assert_str_contains(pages.config(source()).missing, 'недоступна')

    local broken = pages.config(source({
        config = function()
            return nil, 'хранилище решений молчит'
        end,
    }))

    t.assert_equals(broken.missing, 'хранилище решений молчит')

    local silent = pages.config(source({
        config = function()
            return nil
        end,
    }))

    t.assert_str_contains(silent.missing, 'прочитать не удалось')

    local shown = pages.config(source({
        config = function()
            return { groups = {} }
        end,
    }))

    t.assert_equals(shown.config, { groups = {} })
end

--- Выгрузка из названных кусков: отдаёт их по одному и считает вызовы.
---
--- Кусок — текст либо `{ failure = 'слово' }`: на нём источник
--- отказывает парой.
---@param pieces (string|table)[]
---@return table given Источник `audit`, отрезок, с которым его открыли, и счёт вызовов `calls`
local function export(pieces)
    local given = { calls = 0 }

    function given.audit(range)
        given.range = range

        return function()
            given.calls = given.calls + 1

            local piece = pieces[given.calls]

            if type(piece) == 'table' then
                return nil, piece.failure
            end

            return piece
        end
    end

    return given
end

--- Кусок выгрузки: записи с номерами от `first` до `last`, строка на запись.
---@param first integer
---@param last integer
---@return string
local function lines(first, last)
    local text = {}

    for id = first, last do
        table.insert(text, ('{"id":%d,"action":"login"}\n'):format(id))
    end

    return table.concat(text)
end

--- Номера записей страницы — тем же обходом, что у шаблона.
---@param journal table
---@return integer[]
local function drawn(journal)
    local ids = {}

    for record in journal.records do
        table.insert(ids, record.id)
    end

    return ids
end

g.test_the_log_page_reads_the_export_as_it_is_drawn = function()
    -- Строка разобралась, но записью не является: число в журнале — это
    -- не запись журнала. Второй за ней кусок оборван посреди записи.
    -- В куске не осталось ни одной целой записи — берётся следующий.
    local given = export({ lines(1, 2), '5\n{"id":3,"act', lines(4, 5) })
    local shown = pages.audit(source({ audit = given.audit }), { from_id = '1', to_id = '5' })
    local journal = shown.journal

    -- Номера из строки запроса доезжают до источника числами.
    t.assert_equals(given.range, { from_id = 1, to_id = 5 })
    t.assert_equals(shown.range, { from_id = 1, to_id = 5 })

    -- Первый кусок прочитан до ответа, остальные — по мере рисования:
    -- следующий кусок берётся, когда записи прежнего кончились.
    t.assert_equals(given.calls, 1)
    t.assert_equals(journal.records().id, 1)
    t.assert_equals(given.calls, 1)
    t.assert_equals(journal.records().id, 2)
    t.assert_equals(given.calls, 3)
    t.assert_equals(journal.records().id, 4)
    t.assert_equals(given.calls, 3)
    t.assert_equals(journal.records().id, 5)
    t.assert_equals(given.calls, 4)
    t.assert_equals(journal.records(), nil)

    -- Кончившуюся выгрузку страница больше не зовёт.
    t.assert_equals(journal.records(), nil)
    t.assert_equals({ given.calls, journal.shown, journal.next_url }, { 4, 4, nil })
end

g.test_the_stamp_of_a_record_comes_as_a_lua_number = function()
    -- Микросекунды `json.decode` отдаёт целым int64: делится оно нацело,
    -- и дата из него не выходит. Строка вместо числа — не отметка вовсе.
    local given = export({
        '{"id":1,"ts":1789760635145018,"action":"login"}\n{"id":2,"ts":"вчера","action":"login"}\n',
    })
    local journal = pages.audit(source({ audit = given.audit }), {}).journal
    local stamped = journal.records()

    t.assert_type(stamped.ts, 'number')
    t.assert_equals(stamped.ts, 1789760635145018)
    t.assert_equals(journal.records().ts, nil)
end

g.test_the_log_page_stops_at_its_limit_and_links_further = function()
    -- Поток без предела тянул бы журнал целиком одним ответом. Страница
    -- читает до своего предела и на запись вперёд, но не дальше.
    local given = export({ lines(1, 500), lines(501, 1000), lines(1001, 1500), lines(1501, 2000) })
    local shown = pages.audit(source({ audit = given.audit }), {})
    local ids = drawn(shown.journal)

    t.assert_equals({ #ids, ids[1], ids[#ids] }, { 1000, 1, 1000 })
    t.assert_equals(shown.journal.shown, 1000)
    t.assert_equals(shown.journal.next_url, '/audit?from_id=1001')
    t.assert_equals(given.calls, 3)

    -- Граница отрезка переходит на следующую страницу, а начало следующей —
    -- первая запись, не вошедшая в эту: номера после очистки идут с дырами.
    local bounded = export({ lines(1, 1000), lines(1005, 1006) })
    local ended = pages.audit(source({ audit = bounded.audit }), { to_id = '1800' })

    t.assert_equals(#drawn(ended.journal), 1000)
    t.assert_equals(ended.journal.next_url, '/audit?from_id=1005&to_id=1800')
end

g.test_the_log_page_that_ends_on_its_limit_links_nowhere = function()
    -- Ссылка на страницу, где записей нет, — ложное обещание: чтение
    -- на запись вперёд видит, что журнал кончился ровно на пределе.
    local given = export({ lines(1, 1000) })
    local shown = pages.audit(source({ audit = given.audit }), {})

    t.assert_equals(#drawn(shown.journal), 1000)
    t.assert_equals({ shown.journal.shown, shown.journal.next_url, given.calls }, { 1000, nil, 2 })
end

g.test_a_failure_of_the_export_amid_the_page_is_thrown = function()
    -- Заголовки к этому мигу ушли: отказ становится броском, и роутер
    -- рвёт ответ без завершающего куска.
    local given =
        export({ lines(1, 2), { failure = 'спейс app_audit пропал посреди выгрузки' } })
    local shown = pages.audit(source({ audit = given.audit }), {})

    t.assert_equals(shown.journal.records().id, 1)
    t.assert_error_msg_equals(
        'спейс app_audit пропал посреди выгрузки',
        shown.journal.records
    )
end

g.test_a_failure_of_the_first_piece_is_said_on_the_page = function()
    -- Ответ ещё не начат: отказ первого куска — не обрыв, и страница
    -- говорит о нём словами.
    local given = export({ { failure = 'журнал заперт на чтение' } })
    local shown = pages.audit(source({ audit = given.audit }), {})

    t.assert_equals(shown.missing, 'журнал заперт на чтение')
    t.assert_equals(shown.journal, nil)
end

g.test_an_empty_stretch_of_the_log_has_no_journal = function()
    -- Пусто видно до таблицы: страница рисует «записей нет», а не шапку
    -- пустой таблицы.
    for _, pieces in ipairs({ {}, { '5\n' } }) do
        local shown = pages.audit(source({ audit = export(pieces).audit }), {})

        t.assert_equals({ shown.journal, shown.missing }, { nil, nil })
    end
end

g.test_the_range_of_the_log_page_is_parsed_like_that_of_the_export = function()
    -- Форма отбора шлёт оба поля всегда: пустое — не заданное.
    local blank = export({})

    pages.audit(source({ audit = blank.audit }), { from_id = '', to_id = '' })
    t.assert_equals(blank.range, {})

    -- Пределы номера — те же, что у выгрузки API: на пределе принято.
    local edge = export({})

    pages.audit(source({ audit = edge.audit }), { from_id = '1', to_id = '99999999999999' })
    t.assert_equals(edge.range, { from_id = 1, to_id = 99999999999999 })

    -- За пределом — отказ словами проверки, источник не зовётся, а форма
    -- показывает присланное как есть, чтобы его можно было поправить.
    local beyond = export({})
    local shown = pages.audit(source({ audit = beyond.audit }), { from_id = '100000000000000', to_id = '0' })

    t.assert_equals(
        shown.missing,
        'отбор записей журнала не разобран: '
            .. 'from_id должно быть целым числом от 1 до 99999999999999, а не 1e+14; '
            .. 'to_id должно быть целым числом от 1 до 99999999999999, а не 0'
    )
    t.assert_equals(shown.range, { from_id = '100000000000000', to_id = '0' })
    t.assert_equals({ beyond.range, beyond.calls, shown.journal }, { nil, 0, nil })

    local half = pages.audit(source({ audit = beyond.audit }), { to_id = 'много' })

    t.assert_str_matches(
        half.missing,
        '^отбор записей журнала не разобран: to_id должно быть .*много.*$'
    )
end

g.test_the_log_page_says_plainly_when_there_is_no_log = function()
    t.assert_str_contains(pages.audit(source(), {}).missing, 'недоступен')

    local broken = pages.audit(
        source({
            audit = function()
                return nil, 'журнал заперт'
            end,
        }),
        {}
    )

    t.assert_equals(broken.missing, 'журнал заперт')

    local silent = pages.audit(
        source({
            audit = function()
                return nil
            end,
        }),
        {}
    )

    t.assert_str_contains(silent.missing, 'прочитать не удалось')
end

g.test_a_bare_node_shows_an_empty_cluster = function()
    -- Панель на голом узле: источников нет вовсе, и страницы обязаны
    -- рисоваться — пустыми, а не отказом.
    local shown = pages.overview({})

    t.assert_equals(shown.cluster.servers, {})
    t.assert_equals(shown.issues, {})
    t.assert_equals(shown.suggestions, {})
    t.assert_equals(shown.critical, 0)
end
