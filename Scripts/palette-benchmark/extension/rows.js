// Prepended to each command by run.sh, as bundles carry no relative requires: GitLab's project list
// in shape — an SVG letter icon, an accessory and a ~20-action panel on every row.
const { List, ActionPanel, Action, Icon, Color } = require("@raycast/api");
const { jsx, jsxs } = require("react/jsx-runtime");

const groups = ["Platform", "Software / Projects", "IT and Applications", "Singapore Software", "Misc"];
const words = ["dashboard", "frontend", "backend", "infra", "pricing", "agent", "webhook", "factory", "tui", "suite"];

const projects = Array.from({ length: 600 }, (_, i) => {
  const name = `${words[i % words.length]}-${words[(i * 7) % words.length]}-${i}`;
  return { id: i, name, path: `acme / ${groups[i % groups.length]} / ${name}`, stars: i % 13 };
});

function icon(name) {
  const letter = name[0].toUpperCase();
  return `data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#FA6E34" rx="10"/><text x="20" y="28" font-size="22" fill="white" text-anchor="middle">${letter}</text></svg>`;
}

function actions(project) {
  const open = ["Issues", "Merge Requests", "Branches", "Pipelines", "Milestones", "Labels", "Wiki"];
  return jsxs(ActionPanel, {
    children: [
      jsxs(ActionPanel.Section, {
        title: project.path,
        children: [
          jsx(Action.OpenInBrowser, { url: `https://example.com/${project.id}` }),
          jsx(Action.CopyToClipboard, { title: "Copy Project ID", content: String(project.id) }),
          jsx(Action.CopyToClipboard, { title: "Copy Project URL", content: `https://example.com/${project.id}` }),
        ],
      }),
      jsx(ActionPanel.Section, {
        children: open.map((title, index) =>
          jsx(Action.OpenInBrowser, {
            title, icon: Icon.Link, url: `https://example.com/${project.id}/${index}`,
            shortcut: { modifiers: ["cmd"], key: String(index + 1) },
          }, title)),
      }),
      jsx(ActionPanel.Section, {
        title: "Clone",
        children: ["Https", "Ssh", "Zip", "Tarball", "Bundle", "Mirror", "Fork"].map((title) =>
          jsx(Action.CopyToClipboard, { title, content: `${title}:${project.id}` }, title)),
      }),
    ],
  });
}

const row = (project) =>
  jsx(List.Item, {
    title: project.path,
    icon: icon(project.name),
    accessories: [{ icon: { source: Icon.Star, tintColor: Color.SecondaryText }, text: String(project.stars) }],
    actions: actions(project),
  }, String(project.id));
