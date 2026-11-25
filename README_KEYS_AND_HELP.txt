UPDATES (new in 0.29.0)
When the game starts, the mod checks for a newer RE4 Access on the internet.
If there is one, it says "Update available ... Press Shift+F1 to download it."
Shift+F1    Download the update while you play. It installs by itself after you
            close the game. Windows asks for permission once: press Alt+Y.
            A Windows voice tells you when it is installed.
            With no update, Shift+F1 says you have the newest version.
Nothing is downloaded unless you press Shift+F1. To turn the check off,
create an empty file called REAccess_update_off.txt in reframework\data.

EXPLORE MODE AND SIDE QUESTS (new 11/11/2026)
F9          Explore mode on or off (remembered). For finding the way yourself:
            N then only says the goal, how far and which way. No walking help
            (N routes, Shift+Backslash and B are off).
F10         Look around: room size, how far the walls are ahead, right, behind
            and left, and the nearest things worth knowing about.
F11         Next exit: doors, gates, ladders, shutters, elevators, with distance,
            direction, up or down, and "been through". Backslash turns you to it.
Shift+F11   All exits at once.
F12         Side quests: picks your next request, then the main story again.
            With a request picked, N leads to it: the nearest rat, the nearest
            blue medallion, or the Merchant when the request is done.
            Rats: hold L (it aims at the rat), then K. Or knife it with Space.
Shift+F12   The picked request and its progress.
Doors in the castle open when you HOLD W and walk into them.

SETTINGS ON FUNCTION KEYS (new in 0.23.0, saved between games)
F1   Says all the settings below and how they are set now.
F2   Combat speech: full or quiet. Quiet keeps only danger (grabbed, fire, traps, dynamite, low health) and "Enemy down". Off by default.
F3   Walking reports on or off (same as Shift+J).
F4   Short or full messages (same as Slash).
F5   Automatic or spoken turning (same as Shift+Period).
F6   Fight sound on or off.
F7   Hit sound on or off. Off by default. A short click when you lose health.
F8   How far the lists reach for single categories: 300, 100 or 60 meters. The Everything list stays 60.
Shift+N: while a route runs, the same as J. With no route it works like N.
Keys stay silent during cutscenes, in the shop and in the pause menu (only Y works in the pause menu).

WHAT THE SOUNDS MEAN
Fight sound (a thud): NOT an attack. An enemy is within 7 meters on your floor, or within 20 meters and in your way. Repeats every 6 seconds.
Grab buzz: you were grabbed, are burning, or are caught in a bear trap.
Hit click (F7, if turned on): you just lost health.
Stop chime (two bell notes, high then low): on a route you started with N, you have reached a spot where F is needed. Let go of W and listen; the mod then says what to press. For a few seconds after that line, other mod speech waits instead of cutting it off. Danger warnings and anything during a fight still cut in at once.

YOUR OWN KEYS
See REAccess_keys_example.txt in reframework\data.
For P and Shift+P instead of Backslash, H for health and the other layout ideas, see REAccess_keys_ON1XN_layout.txt in the same folder.

RE4 ACCESS - KEYS AND HOW THINGS WORK
For Resident Evil 4 (2023 remake), with NVDA or JAWS. If neither is running, a Windows voice speaks.
Version 0.23.0, 1 November 2026.

FINDING THINGS
Semicolon         Next category of things (Items, Doors and ladders, Enemies, Puzzles, People and places...). Shift+Semicolon goes back.
Right bracket ]   Next thing in the category.  Left bracket [  previous thing.
Backslash         Turn Leon to face the thing you picked.
Shift+Backslash   Walk there: the mod finds the way, you hold W. It says when you have arrived.
H                 Where am I.
Y                 Repeat the last thing the mod said.

WHAT TO DO NEXT
O                 Your current objective.
Shift+O           Map summary: places, objective, nearest typewriter and Merchant, chests, locked doors, ways you have not been yet.
M                 The game's map. The mod reads the same summary when it opens. M closes it.
N                 The next step (puzzle, lever, crank, item the game needs). It walks you there.
Shift+Slash (question mark)   What now: ideas for what to do here.
Slash             Short messages on/off.
J                 How far the route still is.  Shift+J: walking reports (the distance every 10 meters) on or off.  Period: next turn.  Shift+Period: turn directions on/off.
B                 Walk back the way you came.
Comma             Next loot nearby.

PICKING THINGS UP
- When you are close, the mod says "X here. Press F" and then "F ready: X" when F really is on that thing.
- If F is on something else, the mod turns the camera for you until F is on the right thing.
- Items on desks, shelves and inside cabinets: the mod walks you to the floor in front of them.
- Items in a cabinet: walk to it, press F to open it, then F again to take the item.
- Money (pesetas) goes straight to your wallet, not your case. The mod says "Got 1000 pesetas. You have ...".
  Equals key: how much money you have.
- If an item can't be reached yet, the mod tells you why and what opens the way (locked door, puzzle, lever, attic ladder).

DOG IN A BEAR TRAP (Chapter 2-3, outside the Chief's house): walk up to it (Animals category), then HOLD F down for 2 seconds. Tapping F does nothing. The freed dog comes back to help you in a big fight later.
HOLD-F THINGS: some things need F held down for 2 seconds, not tapped (the dog trap, the outhouse toilet lid). The mod says HOLD F when this is the case.
PEARL PENDANT (well by the Chief's manor): it hangs in a lantern over a well. Shoot the stick that holds the well lid open first, then shoot the lantern. The pendant lands on the shut lid; walk up and press F. Lantern first = it falls in the well and gets dirty (sells for much less).

PUZZLES (the mod explains each one when you walk up to it; Y repeats)
- DIAL LOCKS on cabinets: the code is a row of pictures. The clue is always in a document nearby, so read documents (F); the mod reads them aloud.
  Press F at the lock. A and D pick a ring, W and S turn it. The mod says each picture and names the right one when a ring is right. Then press F.
  Chief's house closet: crop, pig, baby (from the Iluminados document). The Crystal Marble is inside.
- CRYSTAL BALL (Chief's house, upstairs, by the bedroom door): press F and choose the Crystal Marble.
  ONE KEY: press F again at the ball. When you hear "Turning the crystal ball", press Backslash: the mod turns it for you.
  Or do it yourself: tap D once and W once: the mod learns how the keys turn the ball.
  It then says which key to hold ("Hold D, 100 degrees"), counts down, and says "Stop. Now hold W".
  Near the end it says "tap" instead of "hold". "Too far" means go back with the key it says.
  Usually three turns. "Lined up" = done. The mod slows the ball down while you turn it, so you can stop in time.
- CHIEF'S ATTIC: the lever behind the bedroom picture is for the attic, but the ladder needs Ashley (later in the story). The mod tells you when.
- EMBLEM STAND (hexagonal crank): Q and E turn the emblem, A flips it, F pushes it in. The mod says "It fits!".
- CRANKS: hold F until the mod says fully turned.
- GATE LATCHES: the bar on a wooden gate. N stands you at it: HOLD F 1 second, then hold W into the gate.
- FALLEN SHELVES: a shortcut. Some corners are a one-way jump down; a fallen shelf is the way back out.
  N walks you to it: HOLD F 1 second to push it over.
- DOCUMENTS: the lists say "already read" or "not read yet". Backslash on one you already read: the mod reads it to you again (the game will not reopen wall maps). Smudged notes are missing letters in the game itself; the mod says so.
- LADDERS: hold F 1 second. After climbing, the mod says "At the top of a ladder" or "At the bottom"; H repeats it.
- BIRD'S NESTS: an item up high can't be reached with F. Step back 3 to 6 meters, hold L (the mod aims), K when it says fire, then F where it falls.
  Branches can block the shot: press Backslash on the item and the mod walks you to a clear spot. After each shot it says Hit (the nest fell) or Missed.
- CHURCH (chapter 3): the church gate, the iron bars inside, the lever, Small Key and Blue Dial are for a LATER chapter.
  In chapter 3 the way on is the TRAPDOOR in the barn by the typewriter. See CHAPTER3_NEXT_STEPS.txt.

END OF A CHAPTER
- The mod says "End of the chapter" and the keys: Enter = next chapter, Tab = chapter results, Escape = pause menu.
  Every screen that opens on top (results, save) is read once.

FIGHTING
L                 Aim. The aim locks onto the nearest enemy.  K: fire.  R: reload.
Apostrophe        Enemies around you: run or fight advice.
X                 Your gun and ammo.  Shift+X: unlimited ammo on or off.
U                 Your health.
Space             Knife: also turns you to the nearest enemy.
See FIGHT_GUIDE.txt for more.

DOCUMENTS AND REQUESTS
Files screen      The mod names each document as you move through the list and reads the whole document when you open it. It also reads radio logs and requests, with progress and reward.
Minus             Reads the next document you missed in the part of the game you have reached. It does not mark the document as found, and nothing from later in the game is included.
Shift+Minus       The requests you have, with area, progress and reward.
Y                 Repeats what was just read.

OPTIONS MENU
Every setting is read with its name, value and its place in the list, then its description: "Screen Resolution: 1920 x 1080, 3 of 40". Q and E change tabs, W and S move, A and D change a value.
PC Specifications reads your CPU, RAM and graphics card. Presets lists each preset with its description. Brightness and Display Area are set by looking at a picture.

LANGUAGES
The mod follows the game's display language if a language file is there: reframework\data\REAccess_lang_<language>.json. See TESTER_NOTES.

KEYS THE MOD NEVER USES: Ctrl, Insert and CapsLock (they belong to JAWS).

- CHURCH DOOR (Chapter 4): the door opens with two head statues placed on the emblem holder: the Apostate's Head (cave in the south of the lake) and the Blasphemer's Head (small cave in the north of the lake). Both are reached by boat. Press N and the mod leads you to the one you are missing. With both, press N at the door: the mod walks you in front of each head statue beside the door; press F there and pick a head.
- SIEGE IN LUIS'S HOUSE ('Stand your ground', Chapter 5): heal to full before you go in. Then stand and fight about 5 minutes until a cutscene ends it: hold L, press K again and again, F after a hit to kick. Number keys: 1 handgun, 2 Flash Grenade, 3 shotgun, 4 Hand Grenade (the mod says them when the siege starts). Grenade into groups of 3, shotgun when they are on you, Tab to heal (the game pauses). Windows are optional: Wooden Planks on the table, F at a window, pick the planks, Use; N helps only when no enemy is close. Full guide: SIEGE_GUIDE.txt.
- MERCHANT, BUYING: pick an item, then HOLD F (about 1 to 2 seconds) until it is bought. A quick tap does nothing; the game fills a gauge while you hold. If F does nothing, hold Enter instead. Q and E switch tabs (BUY, TUNE UP, SELL, TRADE).
- AFTER THE CHURCH INSIGNIA (Chapter 4, 'Head for the church'): the landing below the cliff near the church is a dead end. Take the boat to the Merchant's dock, west of the Boat House (in the boat: N, then Backslash, and the mod drives there). Then on foot press N: the ladder at the back of the dock (hold F to climb), past the Merchant, through a door and uphill to the Quarry, where El Gigante, a giant, ambushes you (the gates close; keep moving, shoot its face; when the parasite comes out of its back press F to climb on and cut it). After the fight N leads along the cliff path to the church front gate (the big gate, not the small side gate to the graveyard): press F at its slot, pick the Church Insignia and choose Use.
- INSIDE THE CHURCH (Chapter 4, find Ashley): 1) Blue Dial: from the entrance take the passage on the RIGHT side to its end; it is in a cupboard there. 2) The Small Key on the table is for a locked drawer elsewhere (optional treasure). 3) Pull the lever on the wall LEFT of the altar: a stand rises with two dials and an empty slot. 4) Press F at the stand and put the Blue Dial in the slot. 5) Stained glass puzzle: each dial (red, green, blue) turns one coloured glass; line them up so the coloured light covers the cult symbol on the floor: green over the centre, red over the body, blue over what is left. Then the gate opens and Ashley is beyond it. The mod helps: at the stand N says how many degrees each glass is off (all three go back to straight, 0 degrees). While you turn, it counts down, says 'wrong way' when it gets worse, then tells you which key to hold, and says 'lined up' for each glass.

- BOAT: N = where to steer. Backslash = the mod drives the whole way to the landing (S or Backslash again = you steer). Near a landing (20 m) it drives in by itself and stops where F gets you off.
- NORTH CAVE (Blasphemer's Head): a symbol button puzzle by the landing opens a shutter. Behind it a ladder goes up to an iron gate; the head is past it. Press N and the mod leads you step by step.
- SYMBOL BUTTON PUZZLE: Right bracket jumps to the next painted symbol not pushed yet, then press Enter to push it (the cursor then moves on by one by itself). Three painted symbols open it (north cave: 4, 6, 7).

CHAPTER 7 CATAPULT FIELD: the big gate only opens to the cannon. Press N: it takes you down into the cannon tower, to a spot where you can shoot the counterweight. Hold L, press K when told; the weight drops and the cannon rises. Press N for the barred door on the way back up. Press N again to reach the cannon and hold F to take it. On the cannon the mod says Right, Left, Up or Down with the degrees left: Left and Right arrows turn, TAP Up and Down arrows to raise and lower. When it says On target, press K. It reloads in about 4 seconds if you miss. Press N: the cannon broke the first gate; walk to the second gate, and when told to stop, let go of W and press F. Press N again for the Merchant and typewriter. Buy all the healing you can at the Merchant at the start of Chapter 7: the field has no herbs near the way, and rocks hit very hard. When a catapult fires the mod says Rock coming: keep moving. L aims at the counterweight only at the shooting spot, with no enemy close.

ASHLEY CARRIED OFF: the mod says Ashley is grabbed and walks you after her while you hold W. When it says Her carrier, hold L: it aims at the enemy carrying her. Press K. An enemy right on top of you comes first. If he gets away with her, the game ends.

AUDIO DESCRIPTION FOR CUTSCENES (new 11/13/2026)
  During cutscenes the mod speaks short descriptions of what happens on screen,
  in the quiet moments between lines of dialogue, so it does not talk over the voices.
  No keys needed. Scenes get descriptions once Claude has written them;
  the mod records every cutscene you watch so Claude can write and time them.

ASHLEY'S PART (Chapter 9) - LANTERN GUARD
When an armor knight comes at Ashley from the side or behind, the mod says where:
"Knight behind left, 4 meters. Hold L." Hold L to raise the lantern: the mod turns Ashley
to the nearest knight so the light freezes it. Let go of L and hold it again for the next knight.
Shift+U (owner copy only): can't die on/off.
