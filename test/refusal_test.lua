--- Тесты каталога отказов панели сверх того, что видно через её адреса.
---
--- Почти всё о каталоге проверяется запросами к панели (`api_test.lua`):
--- отказ собирается там, где случился. Здесь — вид тела сам по себе:
--- его панель отдаёт ядру разделом `http.error_view`, и ядро рисует им
--- всё, что собирает само, — отказы роутера и поломки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.exceptions.refusal')

---@type any
local refusals

g.before_each(function()
    refusals = helper.load('tnt.admin.app.exceptions.refusal')
end)

g.after_each(function()
    helper.unload()
end)

g.test_the_view_draws_the_body_the_panel_reads = function()
    -- Форма тела у панели одна, и задана она здесь: её читают и страницы,
    -- и JS панели, и клиент API. Вид роутера по умолчанию показал бы код
    -- отказа, которого панель не знает.
    local body = refusals.view({
        status = 413,
        message = 'тело запроса слишком велико',
        code = 'router.too_large',
        incident = 'X7K2-9QPA',
    }, {})

    t.assert_equals(body, {
        error = {
            status = 413,
            message = 'тело запроса слишком велико',
            incident = 'X7K2-9QPA',
        },
    })
end

g.test_an_expected_refusal_goes_without_an_incident = function()
    -- Опознаватель есть только у происшествия: назвать его дежурному
    -- можно, а у ожидаемого отказа искать в журнале нечего.
    local body = refusals.view({ status = 404, message = 'нет такого адреса' }, {})

    t.assert_equals(body, { error = { status = 404, message = 'нет такого адреса' } })
end
