{{-- Рамка панели: документ, шапка, меню разделов и место под страницу.

     Разделы берутся из одного списка с маршрутами (`tnt.admin.app.services.pages`):
     раздел, добавленный там, появляется в меню сам, и забыть про него
     нельзя.

     Тема стоит на документе атрибутом `data-bs-theme`: тёмная по
     умолчанию — панель смотрят подолгу и чаще ночью, — а выбранную
     сценарий ставит до первой отрисовки, чтобы страница не моргала
     светлым.

     Адрес толчка (`data-live`) стоит на теле, только когда узел извещает
     о новых снимках: по нему сценарий подписывается на обзор, а без него
     обновляет страницу опросом. --}}
<!doctype html>
<html lang="ru" data-bs-theme="dark">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>@yield('title', 'Кластер') · панель</title>
    <link rel="stylesheet" href="/panel.css">
</head>
<body class="min-vh-100 d-flex flex-column" data-live="{{ live or '' }}">
    <nav class="navbar border-bottom sticky-top bg-body-tertiary">
        <div class="container-fluid gap-2 px-3">
            <a class="navbar-brand d-flex align-items-center gap-2 me-0" href="/">
                <span class="brand-mark" aria-hidden="true"></span>
                <span class="fw-semibold">Кластер</span>
            </a>

            @if (cluster ~= nil and cluster.self_name ~= nil)
            <span class="badge text-bg-secondary font-monospace d-none d-sm-inline">{{ cluster.self_name }}</span>
            @endif

            <div class="ms-auto d-flex align-items-center gap-2">
                <span class="small text-body-secondary d-none d-md-inline" data-taken>
                    обновлено в {{ format.clock(now) }}
                </span>

                <button class="btn btn-sm btn-outline-secondary" type="button" data-refresh title="Обновить сейчас">
                    <span class="d-none d-lg-inline">Обновить</span>
                    <span class="d-lg-none">↻</span>
                </button>

                <button class="btn btn-sm btn-outline-secondary active" type="button" data-auto aria-pressed="true"
                        title="Обновлять само: по толчку узла, а без него — каждые пять секунд">Авто</button>

                <button class="btn btn-sm btn-outline-secondary" type="button" data-theme
                        title="Светлая или тёмная тема"><span data-theme-mark>☾</span></button>
            </div>
        </div>
    </nav>

    <div class="container-fluid flex-grow-1 px-0">
        <div class="row g-0 h-100">
            <div class="col-auto d-none d-md-block border-end bg-body-tertiary">
                <nav class="nav flex-column p-2 panel-menu" aria-label="Разделы">
                    @for (_, item in ipairs(sections))
                    <a class="nav-link d-flex align-items-center gap-2 {{ item.name == section and 'active' or '' }}"
                       href="{{ item.path }}">
                        {{ item.title }}
                        @if (item.name == 'issues' and issues_count ~= nil and issues_count > 0)
                        <span class="badge text-bg-danger ms-auto">{{ issues_count }}</span>
                        @endif
                    </a>
                    @endfor
                </nav>
            </div>

            <main class="col overflow-hidden" data-view>
                <div class="p-3 p-lg-4">
                    @yield('content')
                </div>
            </main>
        </div>
    </div>

    {{-- Меню для узкого экрана: то же самое, но внизу страницы. --}}
    <nav class="nav d-md-none border-top bg-body-tertiary px-2 py-1 justify-content-around" aria-label="Разделы">
        @for (_, item in ipairs(sections))
        <a class="nav-link small {{ item.name == section and 'active text-body' or 'text-body-secondary' }}"
           href="{{ item.path }}">{{ item.title }}</a>
        @endfor
    </nav>

    <script src="/panel.js"></script>
</body>
</html>
