const MANAGE_IMPLIES_VIEW = {
  'inventory.manage': ['inventory.view'],
  'production.daily.manage': ['production.daily.view'],
  'production.downtime.manage': ['production.downtime.view'],
  'production.jh.manage': ['production.jh.view'],
  'quality.inspections.review': ['quality.reports.view'],
  'quality.inspections.record': ['quality.reports.view'],
  'quality.machines.manage': ['quality.live.view'],
  'quality.parts.manage': ['quality.reports.view'],
  'quality.templates.manage': ['quality.setup.view'],
  'quality.parameters.manage': ['quality.analytics.view'],
  'calibration.manage': ['calibration.view'],
  'development.parameters.manage': ['development.parameters.view'],
  'development.drawings.manage': ['development.drawings.view'],
  'development.control_plans.manage': ['development.control_plans.view'],
  'users.create': ['users.view'],
  'users.manage': ['users.view'],
  'roles.manage': ['users.view'],
};

export const can = (user, key) => {
  const permissions = new Set(user?.permissions || []);
  // Keep the UI consistent with User.effective_access(). A manage grant
  // supplies its view grant unless that view was explicitly denied for the user.
  if (user?.access_denials?.includes(key)) return false;
  if (permissions.has(key)) return true;
  return Object.entries(MANAGE_IMPLIES_VIEW).some(([manageKey, viewKeys]) =>
    viewKeys.includes(key) && permissions.has(manageKey)
  );
};
export const canAny = (user, keys) => keys.some((key) => can(user, key));

export function canOpenPath(user, path) {
  const routes = [
    ['/production/jh-inspections', ['production.jh.view']],
    ['/production/downtime', ['production.downtime.view']],
    ['/production/daily-production', ['production.daily.view']],
    ['/reports/daily-production', ['production.daily.view']],
    ['/reports/downtime', ['production.downtime.view']],
    ['/production', ['production.daily.view', 'production.downtime.view', 'production.jh.view']],
    ['/reports/oee', ['quality.analytics.view']],
    ['/reports/setup-approval', ['quality.setup.view']],
    ['/reports', ['quality.reports.view']],
    ['/calibration', ['calibration.view']],
    ['/quality-analyzer', ['quality.live.view', 'quality.reports.view', 'quality.setup.view', 'quality.analytics.view', 'calibration.view']],
    ['/qa', ['quality.live.view', 'quality.reports.view', 'quality.setup.view', 'quality.analytics.view', 'calibration.view']],
    ['/analytics', ['quality.reports.view']],
    ['/machines', ['quality.live.view']],
    ['/inspections', ['quality.reports.view']],
    ['/parameters', ['development.parameters.view']],
    ['/master-database', ['development.parameters.view']],
    ['/development/drawings', ['development.drawings.view']],
    ['/development/control-plans', ['development.control_plans.view']],
    // Master Parameters is a separate module; it must not make the
    // Development landing page appear for users without drawing/control-plan access.
    ['/development', ['development.drawings.view', 'development.control_plans.view']],
    ['/users', ['users.view']],
    ['/hr', ['users.view']],
    ['/purchase', ['purchase.view']],
    ['/store', ['store.view']],
    ['/inventory', ['inventory.view']],
    ['/maintenance', ['maintenance.view']],
    ['/marketing', ['marketing.view']],
    ['/tasks', ['tasks.view']],
    ['/messages', ['messages.use']],
    ['/document-control/approvals', ['document.approve']],
    ['/document-control/dcr', ['document.dcr.view', 'document.dcr.create', 'document.dcr.review', 'document.dcr.approve']],
    ['/document-control', ['document.view']],
    ['/support/bug-reports', ['support.manage']],
  ];
  const route = routes.find(([prefix]) => path === prefix || path.startsWith(`${prefix}/`));
  return route ? canAny(user, route[1]) : true;
}
