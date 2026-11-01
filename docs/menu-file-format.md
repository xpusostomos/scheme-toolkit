
We define a menu like this, basicaly alists of alists of alists

'key is the last segment of the name from the omarchy key
the

'provider is a symbol which represents a scheme function aka (variable-ref (symbol->variable))

(define root-menu
   '((key "apps" icon "" label "Apps" aliases ("app" "applications") provider 'applisting submenu
           (key "label" icon "" label "Learn" submenu
                 (key "keybindings" icon "" label "Keybindings" action "omarchy-launch-webapp 'https://omarchy.org/manual/'")
				 (key "omarchy" icon "" label "Omarchy" action "omarchy-launch-webapp 'http://wiki.hypr.land'")
				 
The output should be indented 2 spaces per level.				 


all the other omarchy values are carried over except:

| 'icon | string | Glyph in the icon column, usually Nerd Font | 333 (every row) |
| 'label | string | Row title; defaults to the id | 333 |
| 'action | string or symbol | Shell command, run detached on select | 275 |
| 'title | string | Header text when the submenu is open; defaults to `label` | 16 |
| provider | string or symbol | Runtime row source (see §6) | 2 |
| when | string or symbol | Bash condition; **hides** the row when it fails | 152 |
| checked | string or symbol | Bash condition; appends ` ✓` when it succeeds | 43 |
| disabled | string or symbol | Bash condition; dims, ticks and disables the row | 0 |
| 'icon-font | string | Font family for the glyph, when it differs from the menu font | 23 |
| 'aliases | string or array | Alternate `summon` routes, also searchable | 20 |
| 'description | string | Subtitle while searching; extra search text | 0 |
| 'search-terms | array of strings | Search-only terms; never routable | 0 |

when, checked or disabled can be a string, if converted from omarchy are a bash 
condition, but can also be a symbol for a procedure, aka (variable-ref (symbol->variable))

I'm suggesting you write a conversion program using guile json reader, and output
the above file format. the tool should be bin/omarchy-menu-to-scheme with #!/usr/bin/guile header

