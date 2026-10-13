"""Stable permission bundles backed by the existing action permissions."""


def _permission(key, label, *keys):
    """Describe one UI permission and the backend actions it controls."""
    return {'key': key, 'label': label, 'keys': sorted(set(keys or (key,)))}


PRODUCTION_VIEW = {
    'production.daily.view', 'production.downtime.view', 'production.jh.view',
}
PRODUCTION_MANAGE = {
    *PRODUCTION_VIEW,
    'production.daily.manage', 'production.downtime.manage',
    'production.jh.submit', 'production.jh.manage',
}
PRODUCTION_MANAGE_ACTIONS = {
    'production.daily.manage', 'production.downtime.manage',
    'production.jh.submit', 'production.jh.manage',
}
QUALITY_VIEW = {
    'quality.live.view', 'quality.reports.view', 'quality.setup.view',
    'quality.analytics.view',
}
QUALITY_MANAGE = {
    *QUALITY_VIEW,
    'quality.inspections.review', 'quality.inspections.record',
    'quality.machines.manage', 'quality.parts.manage',
    'quality.templates.manage', 'quality.parameters.manage',
}
QUALITY_MANAGE_ACTIONS = {
    'quality.inspections.review', 'quality.inspections.record',
    'quality.machines.manage', 'quality.parts.manage',
    'quality.templates.manage', 'quality.parameters.manage',
}
TASK_MANAGE = {'tasks.view', 'tasks.allocate', 'tasks.view_all', 'tasks.manage_all'}
DOCUMENT_MANAGE = {
    'document.view', 'document.view_unapproved', 'document.upload',
    'document.approve', 'document.dcr.view', 'document.dcr.create',
    'document.dcr.review', 'document.dcr.approve',
}
USER_MANAGE = {'users.view', 'users.create', 'users.manage', 'roles.manage'}
ISSUE_MANAGE = {'support.create', 'support.manage'}
INVENTORY_VIEW = {'inventory.view'}
MASTER_DATABASE_VIEW = {'development.parameters.view'}
MASTER_DATABASE_MANAGE = MASTER_DATABASE_VIEW | {'development.parameters.manage'}
MASTER_DATABASE_MANAGE_ACTIONS = {'development.parameters.manage'}
DEVELOPMENT_VIEW = {'development.drawings.view', 'development.control_plans.view'}
DEVELOPMENT_MANAGE = DEVELOPMENT_VIEW | {'development.drawings.manage', 'development.control_plans.manage'}
DEVELOPMENT_MANAGE_ACTIONS = {'development.drawings.manage', 'development.control_plans.manage'}


# The UI exposes module-level choices. Each choice still expands to the
# existing action keys so API checks and old role records remain compatible.
ACCESS_GROUPS = [
    ('Common Access', [
        _permission('messages.use', 'Messages'),
        _permission('document.manage', 'Manage documents', *DOCUMENT_MANAGE),
        _permission('tasks.manage', 'Manage tasks', *TASK_MANAGE),
        _permission('support.manage', 'Report and manage issues', *ISSUE_MANAGE),
    ]),
    ('Production', [
        _permission('production.view', 'View production reports', *PRODUCTION_VIEW),
        _permission('production.manage', 'Manage production reports', *PRODUCTION_MANAGE_ACTIONS),
    ]),
    ('Quality Analyzer', [
        _permission('quality.view', 'View quality reports and analysis', *QUALITY_VIEW),
        _permission('calibration.view', 'View calibration equipment and plans'),
        _permission('calibration.manage', 'Manage calibration equipment and plans'),
    ]),
    ('Master Database', [
        _permission('master_database.view', 'View master database', *MASTER_DATABASE_VIEW),
        _permission('master_database.manage', 'Manage master database', *MASTER_DATABASE_MANAGE_ACTIONS),
    ]),
    ('Development', [
        _permission('development.manage', 'Manage development records', *DEVELOPMENT_MANAGE_ACTIONS),
    ]),
    ('Users and Roles', [
        _permission('users.manage', 'Manage users and roles', *USER_MANAGE),
    ]),
    ('Inventory Management', [
        _permission('inventory.view', 'View inventory management', *INVENTORY_VIEW),
        _permission('inventory.manage', 'Manage inventory receipts and reconciliation'),
    ]),
]

ACCESS_KEYS = {
    key for _, items in ACCESS_GROUPS for item in items for key in item['keys']
} | QUALITY_MANAGE_ACTIONS | DEVELOPMENT_VIEW
# Inspection recording and review are workflow permissions assigned by the
# built-in mobile/supervisor roles. They stay valid for existing roles and API
# validation, but are intentionally omitted from the general report picker.
# Development read keys are retained as internal dependencies of the manage
# bundle and are not shown as a separate choice.
COMMON_ACCESS = DOCUMENT_MANAGE | TASK_MANAGE | ISSUE_MANAGE | {'messages.use'}
# Read access used by operational list endpoints. Keep document DCR actions out
# of this set: DCR creation is common access, but it must not grant read access
# to every production, quality, calibration, or development endpoint.
OPERATIONAL_READ = {
    key for key in ACCESS_KEYS
    if key.startswith(('production.', 'quality.', 'calibration.', 'development.'))
}

# A manage grant always includes the corresponding read access. This keeps
# older custom roles valid after the UI moved to View/Manage bundles.
MANAGE_IMPLIES_VIEW = {
    'inventory.manage': {'inventory.view'},
    'production.daily.manage': {'production.daily.view'},
    'production.downtime.manage': {'production.downtime.view'},
    'production.jh.manage': {'production.jh.view'},
    'quality.inspections.review': {'quality.reports.view'},
    'quality.inspections.record': {'quality.reports.view'},
    'quality.machines.manage': {'quality.live.view'},
    'quality.parts.manage': {'quality.reports.view'},
    'quality.templates.manage': {'quality.setup.view'},
    'quality.parameters.manage': {'quality.analytics.view'},
    'calibration.manage': {'calibration.view'},
    'development.parameters.manage': {'development.parameters.view'},
    'development.drawings.manage': {'development.drawings.view'},
    'development.control_plans.manage': {'development.control_plans.view'},
    'users.create': {'users.view'},
    'users.manage': {'users.view'},
    'roles.manage': {'users.view'},
}
