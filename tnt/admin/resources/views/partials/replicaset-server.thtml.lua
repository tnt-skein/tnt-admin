{{-- Узел в карточке репликасета: имя, роль записи и занятая память.

     Поля: `name` — имя узла, `server` — что о нём известно (может
     не быть вовсе), `writer` — пишет ли он. --}}
<li class="list-group-item">
    <div class="d-flex align-items-center gap-2">
        @include('partials.dot', {
            tone = server ~= nil and format.state_tone(server) or 'secondary',
            blink = server ~= nil and not server.reachable,
        })
        <a class="font-monospace text-decoration-none flex-grow-1 text-truncate"
           href="/cluster?search={{ name }}">{{ name }}</a>
        @if (writer)
        <span class="badge text-bg-success">пишет</span>
        @endif
        @if (server ~= nil and server.retired)
        <span class="badge text-bg-secondary">выведен</span>
        @endif
    </div>

    @if (server ~= nil and server.reachable)
    <div class="mt-2">@include('partials.memory', { ratio = server.memory.arena_ratio })</div>
    @elseif (server ~= nil)
    <p class="small text-danger mb-0 mt-1">{{ server.message or 'не отвечает' }}</p>
    @endif
</li>
