{ lib, config, ... }:
let
  cfg = config.opencode;

  permissionLeafType = lib.types.enum [ "allow" "ask" "deny" ];
  permissionValueType = lib.types.either
    permissionLeafType
    (lib.types.attrsOf permissionLeafType);

  pluginSubmodule = lib.types.submodule {
    options = {
      content = lib.mkOption {
        type = lib.types.lines;
        description = "JavaScript/TypeScript module source for a local OpenCode plugin.";
      };

      extension = lib.mkOption {
        type = lib.types.enum [ "js" "ts" "mjs" "mts" "cjs" "cts" ];
        default = "ts";
        description = "Filename extension for the generated plugin module.";
      };
    };
  };

  commandSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Description shown for the command in OpenCode.";
      };

      agent = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional agent to route this command to.";
      };

      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional model override for this command.";
      };

      template = lib.mkOption {
        type = lib.types.lines;
        description = "Prompt template executed by the command.";
      };
    };
  };

  agentSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "What this agent does.";
      };

      prompt = lib.mkOption {
        type = lib.types.lines;
        description = "System prompt / instructions for the agent.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "primary" "subagent" "all" ];
        default = "all";
        description = "How the agent can be used in OpenCode.";
      };

      hidden = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Hide a subagent from the @ autocomplete menu.";
      };

      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional model override for this agent.";
      };

      tools = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = { };
        description = ''
          Per-agent tool toggles. Example:
          { write = false; bash = true; "devenv_*" = false; }
        '';
      };

      permission = lib.mkOption {
        type = lib.types.attrsOf permissionValueType;
        default = { };
        description = ''
          Per-agent permissions. Values can be simple modes like "allow",
          "ask", or "deny", or nested maps for command-specific permissions.
        '';
      };
    };
  };

  mcpServerSubmodule = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [ "local" "remote" ];
        description = "Type of OpenCode MCP server connection.";
      };

      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the MCP server is enabled.";
      };

      command = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Command array for local MCP servers.";
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables for local MCP servers.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "URL for remote MCP servers.";
      };

      headers = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Headers for remote MCP servers.";
      };
    };
  };

  skillSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Short description used in skill frontmatter.";
      };

      content = lib.mkOption {
        type = lib.types.lines;
        description = "Body of the SKILL.md file after frontmatter.";
      };

      license = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional skill license frontmatter.";
      };

      compatibility = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional compatibility frontmatter.";
      };

      metadata = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Optional skill metadata frontmatter.";
      };
    };
  };

  yamlValue = value:
    if builtins.isBool value then lib.boolToString value
    else if builtins.isInt value then toString value
    else if builtins.isList value then
      if value == [ ] then "[]"
      else "\n" + (lib.concatMapStringsSep "\n" (item: "  - ${yamlScalar item}") value)
    else if builtins.isAttrs value then
      if value == { } then "{}"
      else "\n" + (lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: v:
          let rendered = yamlValue v; in
          if lib.hasPrefix "\n" rendered then "  ${name}:" + rendered else "  ${name}: ${rendered}")
        value))
    else yamlScalar value;

  yamlScalar = value:
    if value == null then "null"
    else if builtins.isString value then lib.generators.toJSON { } value
    else if builtins.isBool value then lib.boolToString value
    else if builtins.isInt value then toString value
    else throw "Unsupported YAML scalar value";

  renderFrontmatter = attrs:
    let
      filtered = lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) attrs;
    in ''
      ---
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: value:
          let rendered = yamlValue value; in
          if lib.hasPrefix "\n" rendered then "${name}:" + rendered else "${name}: ${rendered}")
        filtered)}
      ---
    '';

  agentFile = name: agent:
    let
      frontmatter = renderFrontmatter ({
        inherit (agent) description mode;
      }
      // lib.optionalAttrs (agent.hidden && agent.mode == "subagent") { hidden = true; }
      // lib.optionalAttrs (agent.model != null) { model = agent.model; }
      // lib.optionalAttrs (agent.tools != { }) { tools = agent.tools; }
      // lib.optionalAttrs (agent.permission != { }) { permission = agent.permission; });
    in {
      name = ".opencode/agents/${name}.md";
      value.text = ''
        ${frontmatter}

        ${agent.prompt}
      '';
    };

  commandFile = name: command:
    let
      frontmatter = renderFrontmatter (lib.filterAttrs (_: v: v != null) {
        inherit (command) description agent model;
      });
    in {
      name = ".opencode/commands/${name}.md";
      value.text = ''
        ${frontmatter}

        ${command.template}
      '';
    };

  skillFile = name: skill:
    let
      frontmatter = renderFrontmatter ({
        inherit name;
        inherit (skill) description;
      }
      // lib.optionalAttrs (skill.license != null) { license = skill.license; }
      // lib.optionalAttrs (skill.compatibility != null) { compatibility = skill.compatibility; }
      // lib.optionalAttrs (skill.metadata != { }) { metadata = skill.metadata; });
    in {
      name = ".opencode/skills/${name}/SKILL.md";
      value.text = ''
        ${frontmatter}

        ${skill.content}
      '';
    };

  pluginFile = name: plugin: {
    name = ".opencode/plugins/${name}.${plugin.extension}";
    value.text = plugin.content;
  };

  mcpServers = lib.mapAttrs (_: server:
    if server.type == "local" then
      if server.command == null then
        throw "OpenCode MCP server of type 'local' requires a command array"
      else
        ({
          type = "local";
          command = server.command;
          enabled = server.enabled;
        }
        // lib.optionalAttrs (server.environment != { }) { env = server.environment; })
    else if server.type == "remote" then
      if server.url == null then
        throw "OpenCode MCP server of type 'remote' requires a url"
      else
        ({
          type = "remote";
          url = server.url;
          enabled = server.enabled;
        }
        // lib.optionalAttrs (server.headers != { }) { headers = server.headers; })
    else
      throw "Invalid OpenCode MCP server type: ${server.type}")
    cfg.mcpServers;

  opencodeConfig = lib.filterAttrs (_: v: v != null && v != { } && v != [ ]) {
    "$schema" = "https://opencode.ai/config.json";
    model = cfg.model;
    small_model = cfg.smallModel;
    provider = if cfg.providers == { } then null else cfg.providers;
    instructions = if cfg.instructions == [ ] then null else cfg.instructions;
    tools = if cfg.tools == { } then null else cfg.tools;
    permission = if cfg.permissions == { } then null else cfg.permissions;
    mcp = if cfg.mcpServers == { } then null else mcpServers;
    plugin = if cfg.pluginPackages == [ ] then null else cfg.pluginPackages;
    command = if cfg.commandJson == { } then null else cfg.commandJson;
    agent = if cfg.agentJson == { } then null else cfg.agentJson;
  };
in
{
  options.opencode = {
    enable = lib.mkEnableOption "OpenCode integration with generated config, agents, commands, skills, and plugins";

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional global model id for OpenCode (provider/model-id).";
    };

    smallModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional small_model override for lightweight OpenCode tasks.";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Raw provider configuration to write into the top-level `provider` key of
        opencode.json. Use OpenCode's variable substitution like `{env:NAME}` or
        `{file:path}` inside provider options when needed.
      '';
    };

    instructions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional instruction files or URLs to include via opencode.json.";
    };

    tools = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = { };
      description = ''
        Global tool enable/disable switches for OpenCode. Example:
        { bash = true; write = false; "devenv_*" = false; }
      '';
    };

    permissions = lib.mkOption {
      type = lib.types.attrsOf permissionValueType;
      default = { };
      description = ''
        Global OpenCode permissions. Supports both simple values and nested maps,
        for example:
        {
          edit = "ask";
          bash = { "*" = "ask"; "git status *" = "allow"; };
          task = { "*" = "deny"; "code-reviewer" = "ask"; };
        }
      '';
    };

    pluginPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "npm plugins to load via the top-level `plugin` key in opencode.json.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf pluginSubmodule;
      default = { };
      description = "Local plugin modules to generate under `.opencode/plugins/`.";
    };

    pluginPackageJson = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = ''
        Optional `.opencode/package.json` content for local plugins that depend
        on external npm packages.
      '';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf mcpServerSubmodule;
      default = {
        devenv = {
          type = "local";
          command = [ "devenv" "mcp" ];
          environment = {
            DEVENV_ROOT = config.devenv.root;
          };
        };
      };
      description = "MCP servers to configure for OpenCode.";
    };

    commandJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Optional raw JSON command definitions to write under the top-level
        `command` key in opencode.json.
      '';
    };

    commands = lib.mkOption {
      type = lib.types.attrsOf commandSubmodule;
      default = { };
      description = "Markdown-backed OpenCode custom commands to generate.";
    };

    agentJson = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Optional raw JSON agent definitions to write under the top-level `agent`
        key in opencode.json.
      '';
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf agentSubmodule;
      default = { };
      description = "Markdown-backed OpenCode agents to generate.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf skillSubmodule;
      default = { };
      description = "Project-local OpenCode skills to generate under .opencode/skills.";
    };

    rulesText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Optional AGENTS.md content to generate at the project root.";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.devenv.root}/opencode.json";
      description = ''
        Path to the generated OpenCode JSON config file. The standard OpenCode
        project config location is `${config.devenv.root}/opencode.json`; this
        override exists as an escape hatch for advanced setups.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    files = lib.mkMerge [
      {
        "${cfg.configPath}".json = opencodeConfig;
      }
      (lib.mkIf (cfg.rulesText != null) {
        "AGENTS.md".text = cfg.rulesText;
      })
      (lib.mapAttrs' agentFile cfg.agents)
      (lib.mapAttrs' commandFile cfg.commands)
      (lib.mapAttrs' skillFile cfg.skills)
      (lib.mapAttrs' pluginFile cfg.plugins)
      (lib.mkIf (cfg.pluginPackageJson != null) {
        ".opencode/package.json".json = cfg.pluginPackageJson;
      })
    ];

    infoSections."opencode" = [
      ''
        OpenCode integration is enabled.
        - Config: ${cfg.configPath}
        ${lib.optionalString (cfg.rulesText != null) "- Project rules: ${config.devenv.root}/AGENTS.md"}
        ${lib.optionalString (cfg.commands != { }) "- Commands: ${lib.concatStringsSep ", " (map (name: "/${name}") (lib.attrNames cfg.commands))}"}
        ${lib.optionalString (cfg.agents != { }) "- Agents: ${lib.concatStringsSep ", " (lib.attrNames cfg.agents)}"}
        ${lib.optionalString (cfg.skills != { }) "- Skills: ${lib.concatStringsSep ", " (lib.attrNames cfg.skills)}"}
        ${lib.optionalString (cfg.plugins != { }) "- Local plugins: ${lib.concatStringsSep ", " (lib.attrNames cfg.plugins)}"}
        ${lib.optionalString (cfg.pluginPackages != [ ]) "- npm plugins: ${lib.concatStringsSep ", " cfg.pluginPackages}"}
        ${lib.optionalString (cfg.mcpServers != { }) "- MCP servers: ${lib.concatStringsSep ", " (lib.attrNames cfg.mcpServers)}"}
      ''
    ];
  };
}
