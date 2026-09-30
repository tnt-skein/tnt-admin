{{-- Журнал аудита: кто что сделал с кластером.

     Отрезок задаётся номерами записей, а не временем: номер — это место
     в цепочке, и по нему же проверяется её целость.

     Поля записи — те, что несёт строка выгрузки журнала (`tnt-audit`):
     `ts` — отметка времени в микросекундах, `user` — кто, `action` —
     что, `scope` — над чем.

     Страница идёт потоком: записи — перебор кусков выгрузки, и строки
     таблицы рисуются по мере чтения. Поэтому сколько записей показано
     и есть ли что дальше, известно только после таблицы, и стоит это
     под ней, а не в заголовке. --}}
@extends('layout')

@section('title', 'Журнал')

@section('content')
@include('partials.heading', { title = 'Журнал аудита', note = 'кто что сделал с кластером' })

<form class="d-flex flex-wrap gap-2 mb-3" method="get" action="/audit">
    <input class="form-control form-control-sm font-monospace" style="max-width: 10rem"
           name="from_id" placeholder="с номера" value="{{ range.from_id or '' }}" aria-label="С номера">
    <input class="form-control form-control-sm font-monospace" style="max-width: 10rem"
           name="to_id" placeholder="по номер" value="{{ range.to_id or '' }}" aria-label="По номер">
    <button class="btn btn-sm btn-outline-secondary" type="submit">Показать</button>
</form>

@if (missing ~= nil)
<div class="alert alert-secondary">{{ missing }}</div>
@elseif (journal == nil)
<div class="card"><div class="card-body">
    @include('partials.empty', { message = 'Записей нет', hint = 'на этом отрезке ничего не происходило' })
</div></div>
@else
<div class="card">
    <div class="table-responsive">
        <table class="table table-hover align-middle mb-0">
            <thead>
                <tr class="small text-body-secondary">
                    <th>Номер</th>
                    <th>Когда</th>
                    <th>Кто</th>
                    <th>Что</th>
                    <th>Над чем</th>
                </tr>
            </thead>
            <tbody>
                @for (record in journal.records)
                <tr>
                    <td class="font-monospace small text-body-secondary">{{ record.id }}</td>
                    <td class="small text-nowrap">{{ format.moment(record.ts and record.ts / 1000000) }}</td>
                    <td class="font-monospace small">{{ record.user or '—' }}</td>
                    <td>{{ record.action or '—' }}</td>
                    <td class="small text-body-secondary font-monospace">{{ record.scope or '' }}</td>
                </tr>
                @endfor
            </tbody>
        </table>
    </div>
</div>
<div class="d-flex flex-wrap align-items-center justify-content-between gap-2 mt-3 small text-body-secondary">
    <span>записей на странице: {{ journal.shown }}</span>
    @if (journal.next_url ~= nil)
    <a class="btn btn-sm btn-outline-secondary" href="{{ journal.next_url }}">дальше →</a>
    @endif
</div>
@endif
@endsection
