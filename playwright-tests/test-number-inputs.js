// Run with: node playwright-tests/test-number-inputs.js
// Exercise the actual page handlers without a browser or database writes.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const readPage = (name) => readFileSync(new URL(`../dashboard/src/pages/${name}.jsx`, import.meta.url), 'utf8');
const parameters = readPage('ParametersPage');
const downtime = readPage('DowntimeReportsPage');
const company = readPage('CompanyDetailsPage');

function handler(source, name, context) {
  const match = source.match(new RegExp(`  const ${name} = ([\\s\\S]*?)\\r?\\n  };`));
  assert.ok(match, `Missing handler ${name}`);
  return vm.runInNewContext(`(${match[1]}\n})`, context);
}

for (const setter of ['setNewOpTargetCount', 'setEditTargetCount']) {
  const expression = parameters.match(new RegExp(`onChange=\\{(\\(e\\) => ${setter}\\([^\\n]+)\\}`))[1];
  let value = 1;
  const change = vm.runInNewContext(`(${expression})`, { [setter]: (next) => { value = next; } });
  for (const next of ['', '0', '4', '', '5', '10']) {
    change({ target: { value: next } });
    assert.equal(value, next, `${setter} must preserve typed text`);
  }
}

let reports = [{ no_load: 1 }];
const editCell = handler(downtime, 'handleCellChange', { setReports: (update) => { reports = update(reports); } });
const fields = ['no_load', 'no_operator', 'um', 'setting', 'inspection_wait', 'tool_change', 'power_off', 'rework', 'tool_problem'];
for (const field of fields) {
  for (const next of ['', '0', '4', '', '5']) {
    editCell(0, field, next);
    assert.equal(reports[0][field], next, `${field} must allow clearing and replacement`);
  }
}

let companyState = { lunch_break_minutes: 1, tea_break_minutes: 1 };
const changeCompany = handler(company, 'handleChange', { isAdmin: true, setCompany: (update) => { companyState = update(companyState); } });
for (const name of ['lunch_break_minutes', 'tea_break_minutes']) {
  for (const value of ['', '0', '4', '5']) {
    changeCompany({ target: { name, value, type: 'number' } });
    assert.equal(companyState[name], value);
  }
}

for (const [name, draft] of [['handleSaveOperation', 'newOpTargetCount'], ['handleSaveTargetCount', 'editTargetCount']]) {
  for (const input of ['', '0', '-1', '1.5', '101', '4', '5']) {
    let payload;
    let error;
    const save = handler(parameters, name, {
      [draft]: input, selectedPart: { part_number: 'test' }, selectedTemplate: { id: 1 },
      requireManageAccess: () => true, setError: (value) => { error = value; },
      setSuccessMsg: () => {}, newOpName: '', newOpType: 'first_piece', newOpCycleTime: '', editCycleTime: '',
      createTemplate: async (_, data) => { payload = data; return { data: {} }; },
      updateTemplate: async (_, data) => { payload = data; return { data: {} }; },
      setSelectedTemplate: () => {}, setShowAddOpModal: () => {}, setShowEditTargetModal: () => {},
      setNewOpName: () => {}, setNewOpCycleTime: () => {}, loadTemplates: async () => {},
    });
    await save({ preventDefault() {} });
    if (input === '4' || input === '5') {
      assert.equal(payload.target_parameter_count, Number(input));
    } else {
      assert.equal(payload, undefined, `${name} must reject ${JSON.stringify(input)}`);
      assert.match(error, /whole number/);
    }
  }
}
for (const input of ['', '0', '5', '-1', '1.5']) {
  let payload;
  let error;
  const submit = handler(downtime, 'handleSubmitDowntimeReport', {
    canManageDowntime: true, reports: [{ no_load: input }],
    setError: (value) => { error = value; }, setSaving: () => {}, setSuccessMsg: () => {},
    getExpectedTotal: () => Number(input), getAccountedTotal: () => Number(input),
    api: { post: async (_, data) => { payload = data; } }, dateFilter: '',
    fetchDowntimeReports: () => {}, fetchDowntimeHistory: async () => {}, setActiveTab: () => {},
  });
  await submit();
  if (input === '-1' || input === '1.5') {
    assert.equal(payload, undefined);
    assert.match(error, /non-negative whole numbers/);
  } else {
    assert.equal(payload[0].no_load, Number(input));
  }
}
console.log('Number input regression checks passed: clear, zero, replacement, and save validation.');
