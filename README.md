# Optimiseur Windows

Petit logiciel (Windows 10 / 11) qui libère de la place et allège le PC. Vous choisissez tout :
ce qu'il faut nettoyer, quelles applications désinstaller et quels programmes laisser tourner en arrière-plan.

## Installation

**Le plus simple :** téléchargez **OptimiseurWindows.exe** dans la section *Releases* (à droite de la page),
double-cliquez dessus et acceptez la demande d'administrateur.

> L'exe n'est pas signé : Windows peut afficher « Windows a protégé votre ordinateur ».
> Cliquez sur *Informations complémentaires* → *Exécuter quand même*.

**Sans l'exe :** téléchargez le projet (bouton vert **Code** → *Download ZIP*), décompressez-le
et double-cliquez sur **Lancer.bat**.

Pour recompiler l'exe vous-même : `Install-Module ps2exe -Scope CurrentUser` puis lancez `Build-Exe.ps1`.

## Les 3 onglets

### 1. Nettoyage et réglages
- L'analyse se lance toute seule : la colonne « Gain estimé » montre la place récupérable.
- Cochez / décochez les actions (survolez une ligne pour le détail), puis **Optimiser maintenant**.
- Fichiers temporaires, cache Windows Update, caches des navigateurs, WinSxS, télémétrie, publicités,
  recherche Bing, Widgets, Recall, Game DVR, services inutiles...

### 2. Désinstaller des applications
- Liste **toutes** les applications du Microsoft Store et les programmes installés, avec leur taille.
- Les applications préinstallées inutiles (Bing Actualités, Solitaire, Clipchamp, Candy Crush, TikTok...) sont
  pré-cochées dans le groupe « Recommandé » ; tout le reste est à cocher vous-même.
- Une barre de recherche permet de retrouver une application.
- Les programmes classiques ouvrent leur propre assistant de désinstallation.
- Les éléments indispensables (Store, Sécurité Windows, Edge, Visual C++, .NET...) ne sont pas proposés.

### 3. Démarrage et arrière-plan
- Programmes lancés au démarrage de Windows (Discord, Steam...) et applications du Store autorisées
  à tourner en arrière-plan.
- Cochez puis **Désactiver la sélection** ou **Réactiver la sélection**. Rien n'est supprimé :
  c'est le même réglage que le Gestionnaire des tâches et les Paramètres de Windows, donc 100 % réversible.

Un journal est enregistré dans `Documents\OptimiseurWindows_<date>.log`.

## Sécurité

- Un **point de restauration** est créé avant la première modification (case cochée par défaut).
  Pour annuler : menu Démarrer → « Créer un point de restauration » → *Restauration du système*.
- Les applications du Store supprimées se réinstallent depuis le Microsoft Store.
- Les options risquées (corbeille, Windows.old, veille prolongée, alimentation, effets visuels) sont
  **décochées par défaut**.
- Rien n'est envoyé sur Internet ; tout le code est dans `OptimiseurWindows.ps1`, lisible.
