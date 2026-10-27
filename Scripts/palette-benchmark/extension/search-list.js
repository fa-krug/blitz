// GitLab's shape: the extension takes the search text over, filters itself and throttles.
const { useState } = require("react");

exports.default = function SearchList() {
  const [search, setSearch] = useState("");
  const shown = search ? projects.filter((p) => p.path.includes(search)) : projects;
  return jsx(List, {
    onSearchTextChange: setSearch, throttle: true, searchBarPlaceholder: "Filter Projects by Name...",
    children: jsx(List.Section, { title: "Projects", subtitle: String(shown.length), children: shown.map(row) }),
  });
};
