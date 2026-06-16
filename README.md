# Notes

## Commandes

**quirement are to run theses commandes before in connecting to github:**
```
gh auth login --scopes project
gh repo set-default avenirs-esr/AVENIRS-Project
```

* listing des epics
  * ouvertes (default): `./manage-epic-versions.sh --list`
  * toutes: `STATE=ALL ./manage-epic-versions.sh --list`
  * fermées: `STATE=CLOSED ./manage-epic-versions.sh --list`
  * techniques incluses: `INCLUDE_TECH=true ./manage-epic-versions.sh --list`
  * toutes + tech: `STATE=ALL INCLUDE_TECH=true ./manage-epic-versions.sh --list`
* option de trie sur le listing
  * par version puis par nom (default): `./manage-epic-versions.sh --list`
  * par titre puis par version: `LIST_SORT=title ./manage-epic-versions.sh --list`
* duplication d'une issue à partir de l'ID source: `./manage-epic-versions.sh --duplicate 302 V1`
* duplication de toutes les epics d'une version données vers une version x: `SOURCE_VERSION=MVP ./manage-epic-versions.sh --duplicate-all V1`
* dupliquer toutes les epics vers une V2 `SOURCE_VERSION=ALL STATE=ALL ./manage-epic-versions.sh --duplicate-all V2`

* Duplicating issue:
It's for duplicating epics depending on version: `./duplicate-issue.sh 6 V2` will duplicate the epic with id 6 and applied V2 version

* Check project ids associated on issues:
Check on type: US, Epic and Bug and apply it if missing: `APPLY=true ./sync-issues-projects.sh`
You can set other state of issues by editing the script

* Check version/milestone epics et US
```shell
STATE=ALL ./check-epics-milestones.sh
EXCLUDE_TECH=false ./check-epics-milestones.sh
CHECK_US=false ./check-epics-milestones.sh
```

