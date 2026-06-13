# Notes

## Commandes

**quirement are to run theses commandes before in connecting to github:**
```
gh auth login --scopes project
gh repo set-default avenirs-esr/AVENIRS-Project
```


* Duplicating issue:
It's for duplicating epics depending on version: `./duplicate-issue.sh 6 V2` will duplicate the epic with id 6 and applied V2 version

* Check project ids associated on issues:
Check on type: US, Epic and Bug and apply it if missing: `APPLY=true ./sync-issues-projects.sh`
You can set other state of issues by editing the script
