/* Source links contain project/file identifiers only, never authentication data. */
(() => {
  function parse(hash) {
    if (!hash.startsWith('#config-source?')) return null;
    const query = new URLSearchParams(hash.slice('#config-source?'.length));
    const project = query.get('project'), source = query.get('source');
    if (!project || !source || /[\u0000-\u001f]/.test(project + source)) throw new Error('配置来源链接无效。');
    return {project, source};
  }
  function resolve(link, files) {
    const main = files.find(f => f.role === 'main');
    if (!main || main.path !== link.project) throw new Error('此链接不属于当前实例的项目。');
    const source = files.find(f => f.path === link.source);
    if (!source) throw new Error('此配置来源已移出项目，请回工作台重新检查。');
    return source;
  }
  globalThis.ConfigSourceLink = {parse, resolve};
})();
