{{-- Узлы: таблица всего кластера с отбором и поиском.

     Таблица, а не карточки: когда узлов три десятка, сравнивать их надо
     строка к строке — версии, память, время в работе. Отбор — это адрес,
     и ссылку на него можно послать соседу. --}}
@extends('layout')

@section('title', 'Узлы')

@section('content')
@include('partials.heading', {
    title = 'Узлы',
    note = 'всего ' .. total .. ', показано ' .. #servers,
})

<form class="d-flex flex-wrap gap-2 mb-3" method="get" action="/cluster">
    <div class="btn-group btn-group-sm" role="group" aria-label="Отбор">
        @for (_, item in ipairs(filters))
        <button class="btn btn-outline-secondary {{ item.name == filter and 'active' or '' }}"
                type="submit" name="filter" value="{{ item.name }}">{{ item.title }}</button>
        @endfor
    </div>

    <input class="form-control form-control-sm" style="max-width: 18rem" type="search" name="search"
           placeholder="Имя, репликасет, адрес" value="{{ search or '' }}" aria-label="Поиск узла">
    <input type="hidden" name="filter" value="{{ filter }}">
    <button class="btn btn-sm btn-outline-secondary" type="submit">Найти</button>
</form>

<div class="card">
    <div class="table-responsive">
        <table class="table table-hover align-middle mb-0">
            <thead>
                <tr class="small text-body-secondary">
                    <th>Узел</th>
                    <th class="d-none d-md-table-cell">Репликасет</th>
                    <th class="d-none d-lg-table-cell">Адрес</th>
                    <th>Состояние</th>
                    <th class="d-none d-md-table-cell">Память</th>
                    <th class="d-none d-xl-table-cell">Версия</th>
                    <th class="d-none d-xl-table-cell">В работе</th>
                </tr>
            </thead>
            <tbody>
                @for (_, server in ipairs(servers))
                <tr>
                    <td>
                        <div class="d-flex align-items-center gap-2">
                            @include('partials.dot', {
                                tone = format.state_tone(server),
                                blink = not server.reachable,
                            })
                            <span class="font-monospace">{{ server.name }}</span>
                            @if (server.writable)
                            <span class="badge text-bg-success">пишет</span>
                            @endif
                            @if (server.retired)
                            <span class="badge text-bg-secondary">выведен</span>
                            @endif
                        </div>
                    </td>
                    <td class="font-monospace small text-body-secondary d-none d-md-table-cell">
                        {{ server.replicaset or '—' }}
                    </td>
                    <td class="font-monospace small text-body-secondary d-none d-lg-table-cell">
                        {{ server.uri or '—' }}
                    </td>
                    <td>
                        <span class="text-{{ format.state_tone(server) }}">{{ format.state(server.status) }}</span>
                        @if (not server.reachable and server.last_seen ~= nil)
                        <div class="small text-body-secondary">{{ format.since(server.last_seen, now) }}</div>
                        @endif
                        @if (server.message ~= nil)
                        <div class="small text-danger">{{ server.message }}</div>
                        @endif
                    </td>
                    <td class="d-none d-md-table-cell" style="min-width: 9rem">
                        @if (server.reachable)
                        @include('partials.memory', { ratio = server.memory.arena_ratio })
                        @else
                        <span class="text-body-secondary">—</span>
                        @endif
                    </td>
                    <td class="small text-body-secondary d-none d-xl-table-cell">{{ server.version or '—' }}</td>
                    <td class="small text-body-secondary d-none d-xl-table-cell text-nowrap">
                        {{ format.duration(server.uptime) }}
                    </td>
                </tr>
                @endfor
            </tbody>
        </table>
    </div>

    @if (#servers == 0)
    @include('partials.empty', {
        message = 'Под отбор ничего не попало',
        hint = 'снимите отбор или измените запрос',
    })
    @endif
</div>
@endsection
