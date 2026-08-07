import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods, RemoteFakeIPMethods } from '../../../methods';
import { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { FAKEIP_CHECK_DOMAIN } from '../../../../constants';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const routerFakeIPResponse = await PodkopShellMethods.checkFakeIP();
  const checkFakeIPResponse = await RemoteFakeIPMethods.getFakeIpCheck();
  const checkIPResponse = await RemoteFakeIPMethods.getIpCheck();

  // `data` is whatever the call produced — it is an empty string when
  // check_fakeip printed nothing, and null when the endpoint answered `null`.
  // Reading `.fakeip` off that directly threw a TypeError and killed the
  // whole check, so the card never left its "loading" state.
  const routerData = routerFakeIPResponse.success
    ? (routerFakeIPResponse.data as { fakeip?: boolean } | null)
    : null;
  const browserFakeIPData = checkFakeIPResponse.success
    ? checkFakeIPResponse.data
    : null;
  const browserIPData = checkIPResponse.success ? checkIPResponse.data : null;

  const checks = {
    router: Boolean(routerData?.fakeip),
    browserFakeIP: Boolean(browserFakeIPData?.fakeip),
    differentIP: Boolean(
      browserFakeIPData?.IP &&
        browserIPData?.IP &&
        browserFakeIPData.IP !== browserIPData.IP,
    ),
  };

  // Every sub-check here depends on an external test service. When that
  // service cannot be reached, the check proves nothing either way — reporting
  // a red failure while the tunnel demonstrably works is worse than admitting
  // the test could not run.
  const routerUnreachable =
    !routerData || (routerData as { unreachable?: boolean }).unreachable === true;
  const browserUnreachable = !browserFakeIPData || !browserIPData;
  const testServiceUnreachable = routerUnreachable && browserUnreachable;

  const allGood = checks.router && checks.browserFakeIP && checks.differentIP;
  const atLeastOneGood =
    checks.router || checks.browserFakeIP || checks.differentIP;

  const { state, description } = testServiceUnreachable
    ? {
        state: 'warning' as const,
        description: _('FakeIP test service is unreachable, check skipped'),
      }
    : getMeta({ atLeastOneGood, allGood });

  if (testServiceUnreachable) {
    const local = routerData as {
      local_fakeip?: boolean;
      local_fakeip_address?: string;
    } | null;
    const localFakeIP = Boolean(local?.local_fakeip);

    updateCheckStore({
      order,
      code,
      title,
      description: localFakeIP
        ? _('Test service unreachable, FakeIP verified locally')
        : description,
      state,
      items: [
        {
          state: 'warning',
          key: _('Could not reach the FakeIP test service'),
          value: FAKEIP_CHECK_DOMAIN,
        },
        ...insertIf<IDiagnosticsChecksItem>(localFakeIP, [
          {
            state: 'success',
            key: _('Sing-box hands out FakeIP addresses'),
            value: local?.local_fakeip_address ?? '',
          },
        ]),
      ],
    });

    return;
  }

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.router ? 'success' : 'warning',
        key: checks.router
          ? _('Router DNS is routed through sing-box')
          : _('Router DNS is not routed through sing-box'),
        value: '',
      },
      {
        state: checks.browserFakeIP ? 'success' : 'error',
        key: checks.browserFakeIP
          ? _('Browser is using FakeIP correctly')
          : _('Browser is not using FakeIP'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(checks.browserFakeIP, [
        {
          state: checks.differentIP ? 'success' : 'error',
          key: checks.differentIP
            ? _('Proxy traffic is routed via FakeIP')
            : _('Proxy traffic is not routed via FakeIP'),
          value: '',
        },
      ]),
    ],
  });
}
