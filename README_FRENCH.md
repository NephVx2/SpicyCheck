# SpicyCheck

🇬🇧 [English version](README.md)

Un script de maintenance Windows 11 tout-en-un, en une seule commande : diagnostic de sante complet (CPU, RAM, disques, reseau, batterie, uptime, journaux d'evenements), nettoyage des fichiers temporaires, reparation systeme via DISM/SFC/BCD, optimisation des disques (TRIM/defragmentation), et un rapport HTML avec tableau de bord — le tout suivi en direct dans une console a cadres ASCII et barres de progression, a la maniere d'un outil style "fastfetch".

> Chaque decision de sante (`GOOD`/`MEDIUM`/`CRITICAL`) repose sur un seuil explicite, documente ci-dessous — rien n'est juge sur une simple impression. La detection de corruption DISM/SFC est bilingue (francais/anglais) et nettoie activement la sortie brute des deux binaires, qui peut etre capturee avec des artefacts d'encodage (octets nuls, lettres accentuees mal decodees) selon la configuration de la console — un piege qui, sans ce nettoyage, peut faire disparaitre silencieusement une detection de fichiers corrompus.

---

## Sommaire

- [Langue](#langue)
- [Presentation](#presentation)
- [Captures d'ecran](#captures-decran)
- [Comment fonctionne le diagnostic de sante](#comment-fonctionne-le-diagnostic-de-sante)
- [Les 6 etapes](#les-6-etapes)
- [Notes techniques : detection DISM/SFC bilingue et nettoyage de sortie](#notes-techniques--detection-dismsfc-bilingue-et-nettoyage-de-sortie)
- [Prerequis](#prerequis)
- [Premier lancement](#premier-lancement-pas-a-pas)
- [Parametres en ligne de commande](#parametres-en-ligne-de-commande)
- [Rapports generes](#rapports-generes)
- [Deploiement multi-machines](#deploiement-multi-machines)
- [Depannage](#depannage)

---

## Langue

Depuis la v7.3, le code du script, la sortie console, le rapport HTML et le fichier log sont entierement en anglais, quelle que soit la langue de l'edition Windows sur laquelle il tourne. C'est un changement de langue du code/de l'interface uniquement — le script fonctionne toujours a l'identique sur une machine Windows en anglais comme en francais :

- **La detection de corruption DISM/SFC reste bilingue.** Ces outils repondent dans la langue du systeme, donc les patterns de detection matchent aussi bien la sortie francaise qu'anglaise (voir [Notes techniques](#notes-techniques--detection-dismsfc-bilingue-et-nettoyage-de-sortie)).
- **L'affichage date/heure du rapport HTML suit la langue de l'OS**, pas celle du script — les noms de jour et de mois (`Get-Date -Format 'dddd dd MMMM yyyy'`) s'affichent dans la langue configuree sur la machine Windows elle-meme.

Si vous utilisez une ancienne version de SpicyCheck (anterieure a la v7.3) qui utilisait encore des noms de parametres, de dossiers et un texte console en francais, voir [Parametres en ligne de commande](#parametres-en-ligne-de-commande) et [Rapports generes](#rapports-generes) ci-dessous pour le detail des changements.

**Vous preferez une interface entierement en francais (parametres, messages console, rapport HTML) ?** Les deux versions ont exactement les memes fonctionnalites — seule la langue du code/de l'interface change. La derniere version francaise (v7.2) reste disponible ici : [FRENCH_SpicyCheck v7.2](https://github.com/NephVx2/SpicyCheck-v7.2/releases/tag/v7.2). Elle n'est plus mise a jour ; les correctifs et nouveautes futurs sortiront uniquement sur la version anglaise.

---

## Presentation

`SpicyCheck-v7_3.ps1` execute en une passe un cycle de maintenance Windows 11 complet : affichage des informations systeme (style fastfetch), diagnostic de sante (~16 controles independants), nettoyage des fichiers temporaires/caches, reparation systeme (DISM CheckHealth → ScanHealth → RestoreHealth conditionnel → SFC scannow → verification du bootloader), optimisation des disques (TRIM pour SSD, defragmentation pour HDD), puis generation d'un rapport HTML avec tableau de bord.

Chaque etape est journalisee (`maintenance_<horodatage>.log`) et chaque operation est classee par statut (`OK` / `WARN` / `ERROR` / `SKIP`), affiche en direct dans la console avec code couleur et repris a l'identique dans le rapport HTML final.

---

## Captures d'ecran

<p align="center">
  <a href="screenshots/01-banner-sysinfo.png" target="_blank"><img src="screenshots/01-banner-sysinfo.png" width="49%" alt="Banniere et informations systeme"></a>
  <a href="screenshots/04-html-report.png" target="_blank"><img src="screenshots/04-html-report.png" width="49%" alt="Rapport HTML"></a>
</p>

D'autres captures (resume final, detail complet des operations) sont disponibles dans le dossier [`screenshots/`](screenshots/).

---

## Comment fonctionne le diagnostic de sante

Contrairement a un systeme de score pondere (voir par exemple `Check-Security_Win11` dans cette meme suite), SpicyCheck utilise une logique "pire cas l'emporte" simple et volontairement conservatrice : l'etat general affiche (`GOOD` / `MEDIUM` / `CRITICAL`) correspond au pire statut individuel observe parmi tous les controles de sante. Un seul composant en `CRITICAL` suffit a faire passer tout le diagnostic en `CRITICAL`, quel que soit le nombre de composants par ailleurs sains.

**Seuils appliques par controle :**

| Controle | MEDIUM | CRITICAL |
|---|---|---|
| Charge CPU | > 70% | > 90% |
| Frequence CPU (throttling) | < 40% de la frequence max | — |
| Temperature (par zone) | > 75°C | > 90°C |
| Utilisation RAM | > 75% | > 90% |
| Pagefile | > 50% | > 80% |
| Espace disque libre | < 20% | < 10% |
| Sante SMART (par disque) | `Warning` | tout sauf `Healthy`/`Warning` |
| Ping passerelle | > 80 ms | > 200 ms |
| Batterie (en decharge) | < 40% | < 20% |
| Uptime | > 30 jours | > 60 jours |
| Evenements Systeme/Application (1h, niveau Erreur/Critique) | > 5 | > 20 |

Ce meme diagnostic alimente a la fois le score affiche en direct dans la console pendant l'etape 2/6, **et** le rapport HTML final ainsi que le resume console de fin de run — les deux utilisent la meme source de donnees (`$Script:Health`), garantissant que ce qui s'affiche pendant le run correspond exactement a ce que le rapport archive.

---

## Les 6 etapes

<details>
<summary><strong>1 · Informations systeme (banniere style fastfetch)</strong></summary>

Affiche un panneau complet : OS/build, machine/BIOS, uptime, CPU (modele, architecture, coeurs, frequence, cache, virtualisation, charge), GPU(s) (VRAM, resolution, pilote), RAM (total, utilisee, barrettes, fabricant, configuration canal), stockage (par lettre de lecteur : espace, type SSD/HDD/bus, sante, systeme de fichiers), reseau (interface active, IP), temperatures. Alimente en parallele une partie des controles de sante.
</details>

<details>
<summary><strong>2 · Diagnostic de sante</strong></summary>

~16 controles independants : CPU (charge + frequence), zones de temperature, RAM (utilisation + pagefile), chaque disque (espace libre + sante SMART individuelle), chaque GPU, chaque interface reseau active + ping passerelle, batterie (si presente), uptime systeme, journal d'evenements (erreurs/critiques de la derniere heure). Se termine par un encart "Etat de sante global" avec le statut agrege.
</details>

<details>
<summary><strong>3 · Nettoyage systeme</strong></summary>

TEMP utilisateur, TEMP systeme (`C:\Windows\Temp`), Prefetch (fichiers `.pf` uniquement — le dossier lui-meme n'est jamais supprime), cache Windows Update (`SoftwareDistribution\Download`), cache des miniatures/icones (`thumbcache_*.db`/`iconcache_*.db`), cache Internet (`INetCache`), logs CBS (`.log`/`.cab` dans `Windows\Logs\CBS`), purge du cache DNS, vidage de la corbeille. Chaque etape rapporte l'espace libere.
</details>

<details>
<summary><strong>4 · Reparation systeme</strong></summary>

Enchainement strict : `DISM /CheckHealth` → `DISM /ScanHealth` → **si et seulement si** une corruption a ete detectee par l'une des deux etapes precedentes, `DISM /RestoreHealth` (sinon l'etape est marquee `SKIP`, jamais lancee inutilement) → `SFC /scannow` → verification du bootloader (`bcdedit /enum`). La detection de corruption DISM et l'analyse des 4 issues possibles de SFC (aucune violation / repare / non reparable / echec d'operation) sont bilingues francais/anglais et tolerantes aux artefacts d'encodage de la console — voir la section technique ci-dessous.
</details>

<details>
<summary><strong>5 · Optimisation disques</strong></summary>

Pour chaque volume monte avec une lettre de lecteur : TRIM (`Optimize-Volume -ReTrim`) si SSD detecte, defragmentation classique si HDD, passe generique `Optimize-Volume` si le type n'a pas pu etre determine. Termine par un nettoyage du dossier WinSxS (`DISM /StartComponentCleanup`).
</details>

<details>
<summary><strong>6 · Generation des rapports</strong></summary>

Rapport HTML unique (voir [Rapports generes](#rapports-generes)) contenant : bandeau d'etat general, cartes de synthese (operations/succes/warnings/erreurs/ignores + repartition sante + duree), panneau "Informations Systeme", panneau "Diagnostic de Sante", et tableau complet "Detail des Operations" groupe par section. Export JSON optionnel via `-ExportJSON`.
</details>

---

## Notes techniques : detection DISM/SFC bilingue et nettoyage de sortie

Deux pieges ont ete identifies et corriges au fil du developpement, documentes ici pour eviter toute regression :

**1. Localisation.** La sortie de `dism.exe` et `sfc.exe` est dans la langue du systeme. Une detection basee uniquement sur les chaines anglaises (`"repairable"`, `"did not find any integrity violations"`, etc.) ne matche jamais sur un Windows en francais — une corruption pouvait etre detectee par DISM sans jamais declencher `RestoreHealth`. Toutes les detections sont desormais bilingues (`repairable|reparable`, `aucune violation`, etc.).

**2. Encodage console.** Sur certaines configurations, la sortie de `sfc.exe` (et parfois `dism.exe`) est capturee avec un octet nul intercale entre chaque caractere et les lettres accentuees mal decodees (artefact UTF-16LE relu en codepage OEM/CP437 — `e` accent aigu devient `U` accent aigu majuscule, `e` accent grave devient `THORN` majuscule, etc.). Sans nettoyage, un texte pourtant correctement detecte par la regex en test peut ne jamais matcher sur la sortie reelle de la machine, faisant retomber silencieusement une detection critique sur le statut generique `OK`. La fonction `ConvertTo-CleanOutput` nettoie systematiquement cette sortie (suppression des octets nuls et caracteres de controle) avant tout matching, sur les 4 appels DISM/SFC concernes.

---

## Prerequis

- Windows 11 (le script cible specifiquement `dism`, `sfc`, `bcdedit`, `defrag`, ainsi que les cmdlets `Storage`/`NetAdapter`/`NetTCPIP` livrees avec Windows 11).
- PowerShell 5.1 (integre a Windows) ou PowerShell 7+.
- Droits administrateur (`#Requires -RunAsAdministrator` — le script refuse de demarrer sans, aucune auto-elevation).
- Binaires `dism.exe`, `sfc.exe`, `bcdedit.exe`, `defrag.exe`, `ipconfig.exe` accessibles dans le `PATH`.
- Si le script est signe numeriquement (recommande en `-ExecutionPolicy AllSigned`/`RemoteSigned`) : le certificat de signature doit etre approuve sur la machine cible.

---

## Premier lancement (pas a pas)

1. Copier `SpicyCheck-v7_3.ps1` sur la machine cible.

2. Ouvrir PowerShell **en tant qu'Administrateur** — le script exige l'elevation des le depart et ne s'auto-eleve pas.

   Puis se placer dans le dossier qui contient le script (adapter le chemin ; garder les guillemets s'il contient des espaces) :

   ```powershell
   cd "$HOME\Downloads"
   ```

3. **Debloquer le script** s'il a ete telecharge depuis Internet. Windows marque les fichiers telecharges, et la politique d'execution de PowerShell (`RemoteSigned`, par exemple) refuse de lancer un script marque. Dans cette meme fenetre Administrateur, depuis le dossier du script :

   ```powershell
   Unblock-File .\SpicyCheck-v7_3.ps1
   ```

   Si PowerShell indique plutot que l'execution de scripts est desactivee sur ce systeme (la politique par defaut de Windows est `Restricted`), autoriser d'abord les scripts pour le compte courant (la modification ne s'applique qu'a ce compte, pas a toute la machine) :

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```

   Toujours bloque ? Voir le [guide pas a pas](https://github.com/NephVx2/Script-blocked-Look-at-this/blob/main/README_POWERSHELL_FRENCH.md).

4. Lancer d'abord le self-test — aucun fichier ecrit, aucune modification systeme :

   ```powershell
   .\SpicyCheck-v7_3.ps1 -SelfTest
   ```

   Execute 36 assertions internes (fonctions utilitaires, binaires requis presents, cmdlets et classes WMI interrogeables, dossier de rapports accessible en ecriture, session elevee). Code de sortie `0` = tout passe, `1` = au moins un echec.

5. Lancer le run complet :

   ```powershell
   .\SpicyCheck-v7_3.ps1
   ```

   Suivre en direct la progression a travers les 6 etapes (`Step X / 6`) dans la console, avec le detail colore de chaque operation. La phase de reparation (DISM ScanHealth notamment) est generalement la plus longue.

6. A la fin, la console affiche le "Final Summary" (duree, compteurs OK/WARN/ERROR, etat de sante global) puis un tableau detaille de toutes les operations.

7. Le script demande `Open in browser? [Y/n]` — repondre `Y` (ou Entree) ouvre directement le rapport HTML genere.

8. Pour des runs automatises ou repetes, utiliser `-Silent` (voir ci-dessous) et consulter uniquement le rapport HTML apres coup.

---

## Parametres en ligne de commande

| Parametre | Description |
|---|---|
| `-SkipCleanup` | Ignore l'etape 3 (nettoyage). |
| `-SkipRepair` | Ignore l'etape 4 (DISM/SFC/BCD). |
| `-SkipOptimization` | Ignore l'etape 5 (TRIM/defragmentation/WinSxS). |
| `-Silent` | Desactive tout affichage console (banniere, progression, resume, prompt d'ouverture du navigateur, pause finale). Les rapports sont generes normalement — pense pour une tache planifiee. |
| `-ExportJSON` | Exporte en plus l'ensemble des resultats bruts au format JSON (`report_<horodatage>.json`). |
| `-SelfTest` | Execute la batterie de 36 assertions internes puis quitte. Aucun rapport genere, rien de modifie sur le systeme. Code de sortie `0`/`1`. |

**Exemples :**

```powershell
.\SpicyCheck-v7_3.ps1 -SelfTest
.\SpicyCheck-v7_3.ps1
.\SpicyCheck-v7_3.ps1 -Silent -ExportJSON
.\SpicyCheck-v7_3.ps1 -SkipOptimization
```

---

## Rapports generes

Chaque run reel (hors `-SelfTest`) ecrit dans :

```
%USERPROFILE%\Desktop\Maintenance_Reports\
```

| Fichier | Contenu |
|---|---|
| `report_<horodatage>.html` | Tableau de bord complet : bandeau d'etat general, cartes de synthese, panneau Informations Systeme, panneau Diagnostic de Sante, tableau complet Detail des Operations groupe par section |
| `maintenance_<horodatage>.log` | Journal texte brut horodate de chaque operation, y compris la sortie brute (nettoyee) de DISM/SFC — utile pour le diagnostic apres-coup |
| `report_<horodatage>.json` | Export JSON complet de l'ensemble des resultats (uniquement si `-ExportJSON`) |

En cas d'erreur fatale non geree, un fichier `MAINTENANCE_ERROR.txt` est egalement ecrit directement sur le Bureau.

---

## Deploiement multi-machines

1. **Distribuer** le fichier `.ps1` vers chaque machine cible.

2. **Approuver le certificat de signature** si une politique d'execution stricte est en place (`-ExecutionPolicy AllSigned`/`RemoteSigned`).

3. **Executer `-SelfTest` en premier** sur chaque machine pour confirmer que le script lui-meme est intact et que les prerequis (binaires, cmdlets, classes WMI) sont disponibles.

4. **Planifier via le Planificateur de taches Windows** avec `-Silent`, en s'executant en tant qu'Administrateur (obligatoire — pas d'auto-elevation) :

   | Champ | Valeur |
   |---|---|
   | Programme/script | `pwsh.exe` (ou `powershell.exe`) |
   | Arguments | `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\SpicyCheck-v7_3.ps1" -Silent` |
   | Executer avec les autorisations maximales | Oui |

5. Les rapports et logs sont **propres a chaque machine**, ecrits localement sur le Bureau de l'utilisateur executant la tache — aucune donnee n'est centralisee automatiquement. Pour une vue consolidee sur un parc, prevoir une etape de collecte separee par-dessus ce script.

6. La detection bilingue DISM/SFC couvre le francais et l'anglais ; si le parc inclut des machines dans une **troisieme langue**, verifier manuellement (via `-SelfTest` puis un run reel avec examen du `.log`) que les messages DISM/SFC de cette langue sont bien reconnus avant de generaliser le deploiement.

---

## Depannage

<details>
<summary><strong>PowerShell indique que le script est bloque, "n'est pas signe numeriquement", ou que l'execution de scripts est desactivee</strong></summary>

Deux mecanismes entrent en jeu, et le correctif depend du message :

- **"n'est pas signe numeriquement"** (`is not digitally signed` sur un Windows en anglais, avec `RemoteSigned`) : Windows a marque le fichier comme telecharge. Lancer `Unblock-File .\SpicyCheck-v7_3.ps1` (ou cocher **Debloquer** dans les Proprietes du fichier). Si le script vient d'un `.zip`, debloquer le `.zip` avant de l'extraire.
- **"l'execution de scripts est desactivee sur ce systeme"** (`running scripts is disabled on this system`) : la politique d'execution est `Restricted`. Lancer `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`, puis debloquer le fichier comme ci-dessus.
- **Rien ne marche** : `Get-ExecutionPolicy -List` indique si une strategie de groupe impose le reglage (`MachinePolicy` ou `UserPolicy` different de `Undefined`) — seul l'administrateur de la machine peut la changer.

Le [guide pas a pas](https://github.com/NephVx2/Script-blocked-Look-at-this/blob/main/README_POWERSHELL_FRENCH.md) detaille tout cela, avec en plus les avertissements SmartScreen/Defender et un lancement ponctuel avec `-ExecutionPolicy Bypass`.
</details>

<details>
<summary><strong>Le script ne demarre pas du tout</strong></summary>

Il exige les droits Administrateur des le depart (`#Requires -RunAsAdministrator`) et ne s'auto-eleve pas — faire un clic droit sur PowerShell et choisir "Executer en tant qu'administrateur", ou lancer depuis un terminal deja eleve.
</details>

<details>
<summary><strong>Le "Diagnostic de Sante" du rapport HTML ne correspond pas a ce qui s'est affiche en console pendant le run</strong></summary>

Ne devrait plus arriver depuis que les deux vues partagent la meme source de donnees. Si un ecart est observe, comparer le `.log` du run avec le rapport HTML et le signaler — c'est probablement une regression.
</details>

<details>
<summary><strong>DISM ScanHealth trouve une corruption mais RestoreHealth ne se declenche pas</strong></summary>

Verifier dans le `.log` la ligne `DISM ScanHealth :` et confirmer que le texte contient bien `repairable` ou `reparable`. Si le message est dans une autre langue que le francais ou l'anglais, la detection ne le reconnaitra pas — voir [Notes techniques](#notes-techniques--detection-dismsfc-bilingue-et-nettoyage-de-sortie).
</details>

<details>
<summary><strong>SFC affiche "Verification completed" au lieu d'un statut precis</strong></summary>

C'est le comportement de repli attendu si aucun des 4 patterns connus (aucune violation / repare / non reparable / echec) ne matche — generalement revelateur d'un message SFC inhabituel ou d'une langue non couverte. Inspecter la ligne `SFC :` dans le `.log` (deja nettoyee des octets nuls) pour identifier le texte exact.
</details>

<details>
<summary><strong>-SelfTest signale un echec</strong></summary>

Lire directement le nom de l'assertion en echec dans la console ou le `.log` — il pointe vers une fonction, un binaire ou une cmdlet manquante precise, pas vers l'etat de sante reel de la machine.
</details>

---

<sub>SpicyCheck — maintenance Windows 11 en une commande, diagnostic de sante a 16 controles, reparation DISM/SFC/BCD bilingue, self-test a 36 assertions.</sub>
