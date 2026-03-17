# OpenBrowse Example

Install Micro Startup into the OpenBrowse repo:

```bash
cd /Users/isaaczhang/Desktop/AGENT/Project_OpenBrowse
/Users/isaaczhang/Desktop/AGENT/Micro_Startup/install.sh
```

Initialize and inspect the default crew:

```bash
./micro-startup init
./micro-startup role list
./micro-startup doctor
```

Add a custom advisor or writer:

```bash
./micro-startup role add qa --archetype advisor
./micro-startup role add reviewer --archetype writer
```

Optional overrides:

```bash
cp .micro-startup/config.env.example .micro-startup/config.env
```

For example:

```bash
WRITER_BRANCH_PREFIX="codex/openbrowse"
```

Then start the crew runtime:

```bash
./micro-startup start
```

This keeps the automation fully inside the OpenBrowse repo while allowing the crew to grow beyond the original fixed triad.
