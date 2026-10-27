// The other common shape: no onSearchTextChange, so Blitz filters the rows itself.
exports.default = function FilterList() {
  return jsx(List, { children: jsx(List.Section, { title: "Projects", children: projects.map(row) }) });
};
