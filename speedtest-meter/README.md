# Speedtest Meter — plugin Noctalia v5

Widget na barra + painel com velocímetro e tela final de dados técnicos completos.

## Funciona independente da distro (dois backends)

O painel detecta, nessa ordem, qual ferramenta de speedtest existe no sistema:

1. **`speedtest`** (Ookla CLI oficial) — dá progresso linha a linha em JSON, então o velocímetro
   é 100% em tempo real (ping → download → upload). Em Arch normalmente vem via AUR
   (ex.: `yay -S speedtest-bin`, `ookla-speedtest-bin` ou `ookla-speedtest-cli-bin` — os nomes
   mudaram algumas vezes no AUR, vale conferir com `yay -Ss speedtest` qual está disponível hoje).
2. **`speedtest-cli`** (Python, pacote `speedtest-cli`) — está nos repositórios oficiais da
   maioria das distros, inclusive **Arch** (`sudo pacman -S speedtest-cli`, sem precisar de AUR).
   Essa ferramenta não expõe progresso incremental, então nesse modo o velocímetro pulsa (efeito
   "carregando") em vez de mostrar Mbps ao vivo — o resultado final continua completo.

Se nenhum dos dois existir, a tela de erro detecta seu gerenciador de pacotes
(pacman/apt/dnf/zypper/apk) e mostra o comando de instalação certo — no seu caso, Arch, isso é
`sudo pacman -S speedtest-cli`.

## Ícone do widget

Na tela inicial do painel tem um campo "Ícone do widget": digite qualquer texto ou um glyph (por
exemplo, um caractere de Nerd Font) e clique em "Salvar". O widget da barra atualiza na hora — a
preferência fica salva via `noctalia.state`, compartilhado entre o painel e o widget. (Tentei
antes deixar isso como uma configuração nativa do widget via `[[config]]` no `plugin.toml`, mas
sem o schema real de configurações do Noctalia documentado, a opção simplesmente não apareceu na
tela de configurações — então voltei pro campo dentro do painel, que usa só API documentada e
funciona garantido.)

## Detecção de backend corrigida — causa raiz confirmada

No Arch, o pacote oficial `speedtest-cli` instala **dois** binários: `speedtest-cli` e também
`speedtest` (ambos são o mesmo script Python, com nomes diferentes). Antes, o plugin via
`speedtest` no PATH e concluía "é o CLI oficial da Ookla" — mas nesse caso é o Python, que não
entende as flags `--format=json --progress=yes`, então não produzia nada útil e o velocímetro
ficava travado em "Preparando...".

Agora, antes de confiar em `speedtest`, o plugin roda `speedtest --version` e só usa o backend
"ookla" (streaming ao vivo) se a saída mencionar "Ookla". Caso contrário — como no seu caso —, cai
automaticamente pro backend "legacy" via `speedtest-cli` (que você confirmou funcionar 100% no
terminal), com o velocímetro em modo "pulso" (sem progresso incremental, mas resultado final
completo).

## Pontos que você deve conferir/ajustar

O `.txt` que você me passou documenta a API Luau em runtime (`noctalia.*`, `ui.*`, `panel.*`,
callbacks de entrada), mas **não** documenta:

- **O schema do `plugin.toml`** — escrevi por convenção; compare com o `plugin.toml` do seu
  `link-ip-monitor` (que já funciona) se algo não carregar.
- **As props exatas de `ui.progress`** (se `orientation = "circular"` existe mesmo) e de
  `ui.input` (`value`/`placeholder`/`onChange`) — são melhores palpites, comentados no código.
  Se `ui.input` não aceitar `onChange`, o campo de ícone pode precisar de ajuste.

## Arquivos

- `plugin.toml` — manifesto do plugin.
- `widget.luau` — widget da barra (ícone configurável + abre o painel).
- `panel.luau` — toda a lógica: detecção de backend/distro, streaming ou execução do teste,
  normalização do resultado, persistência do último resultado, geolocalização extra do cliente,
  e o campo de ícone do widget.
- `translations/en.json`, `translations/pt-BR.json` — strings de interface.
