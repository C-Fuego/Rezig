# zeraora

Print pokemon sprites in your terminal.

Zeraora reads the same sprite set and pokedex data as
[krabby](https://github.com/yannjor/krabby) and keeps its command line and
configuration format, so it can be dropped in place of it. Everything is
embedded in the binary: no data files, no runtime lookups.

![](https://i.imgur.com/MVzaS3k.png)

## Features

- Pokemon from every generation, including shinies, megas, gigantamax and
  regional variants
- Print a random pokemon, optionally filtered by generation and form
- Print pokemon by name, with pokedex entry and left padding
- TOML config for language and shiny rate
- Single static binary, about 8 MB, under 1 ms startup

## Building

Needs Zig 0.18 (0.18.0-dev.935 or newer).

```
zig build -Doptimize=ReleaseFast
```

The binary lands in `zig-out/bin/zeraora`. `zig build` on its own produces a
debug build, `zig build test` runs the unit tests.

The build packs the assets once and leaves two generated files in the project
root, both gitignored: `db.bin`, the pokedex compiled from
`assets/pokemon.json`, and `sprites.bin`, every colorscript gzipped into a
single self-indexing pack (20 MB down to 2.4 MB). Startup does no parsing, it
points straight at those bytes and inflates just the one sprite it prints.

On Arch, the bundled `PKGBUILD` builds and installs it the usual way:

```
makepkg -si
```

## Usage

```
zeraora <COMMAND>
```

| Command  | What it does                                        |
| -------- | --------------------------------------------------- |
| `list`   | Print every pokemon slug, optionally by generation  |
| `name`   | Print one pokemon by name                           |
| `random` | Print a random pokemon                              |
| `help`   | Print the help of a subcommand                      |

```
zeraora name charizard
zeraora name spheal -s
zeraora name mudkip -i
zeraora name blastoise -f mega
zeraora name abra --padding-left 4 --no-title
zeraora random 1-3
zeraora random 1,3,6
zeraora random --no-mega --no-gmax --no-regional
zeraora list 4
```

Forms are spelled `mega`, `mega-x`, `mega-y`, `gmax`, `alola`, `galar`,
`hisui`, `paldea`, and a few one-offs such as `primal`, `sky`, `therian` and
`unbound`. Generations are `1` to `9`, a range `1-3`, or a list `1,3,6`.

## Configuration

The first run creates `$XDG_CONFIG_HOME/zeraora/config.toml` (usually
`~/.config/zeraora/config.toml`):

```toml
# The language to use when printing the pokemon's name and/or description.
# Possible options include en (English), fr (French), de (German), ja (Japanese),
# zh_hans (Chinese with simplified characters), zh_hant (Chinese with traditional characters)
language = "en"

# The probability to show a shiny pokemon when using the random command
shiny_rate = 0.0078125
```

## Credits

- [krabby](https://github.com/yannjor/krabby) by Yann Jorelle, the project this
  is a rewrite of, GPL-3.0
- Sprites: [PokéSprite](https://msikma.github.io/pokesprite/), converted to
  unicode with [pokemon-generator-scripts](https://gitlab.com/phoneybadger/pokemon-generator-scripts)
- Pokedex data: [PokéAPI](https://github.com/PokeAPI/pokeapi)

Licensed under the GPL-3.0, same as the upstream project.
