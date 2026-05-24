# Kleine Erweiterung für gptel-send

Im `org-mode` will ich `gptel-send` so erweitern, dass 
die system message über einen besonders markierten
`subtree`definiert wird. `gpt-send` soll dann so erweitert
werden, dass die system-message aus diesem `subtree`
verwendet wird. Dieser subtree soll immer am Ende des
buffers liegen. `gptel-send` schickt ja nur den Teil
des buffers bis zum cursor. Wenn der cursor also
vor dem `system-message-subtree` subtree steht, wird
er nicht als message übertragen, sondern nur als
`system-message` gesendet.

Diese Funktion will ich später so erweitern, dass
sie auch auf andere Dateitypen erweitert wird, also
z.B. auf lisp-Dateien. Der einzige Unterschied wäre dann,
dass dije system message (Am Ende der Datei) anders markiert
werden müsste. Allerdings immer auf eine Weise,
dass die Datei gültig bleibt. Im Falle von lisp
müsste es also eine gültige lisp-Datei bleiben, und 
die system message müsste vom lisp interpreter ignoriert
werden. 

Im ersten Schritt soll es erst mal für org-Dateien
funktionieren. Ich weiss noch nicht genau,
wann ich die Erweiterung auf lijsp (und andere Formate)
brauche.

Du machst mir ein Konzept für das alles und speicherst
das unter `gptel-send-extension-concept.md` . 

