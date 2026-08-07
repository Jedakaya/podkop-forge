import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { PodkopShellMethods } from '../../../methods';
import { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';
import { store } from '../../../services';

function formatExpiry(expireTs: number): string {
  if (expireTs <= 0) return '';
  return new Date(expireTs * 1000).toLocaleDateString();
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return `${(bytes / Math.pow(1024, i)).toFixed(1)} ${units[Math.min(i, units.length - 1)]}`;
}

export async function runDnsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.DNS;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const [dnsChecks, userinfoResult] = await Promise.all([
    PodkopShellMethods.checkDNSAvailable(),
    PodkopShellMethods.getSubscriptionUserinfo(),
  ]);

  if (!dnsChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('DNS checks failed');
  }

  const data = dnsChecks.data;

  store.set({ dnsFailoverActive: Boolean(data.dns_failover_active) });

  const allGood =
    Boolean(data.dns_on_router) &&
    Boolean(data.dhcp_config_status) &&
    Boolean(data.bootstrap_dns_status) &&
    Boolean(data.dns_status);

  const atLeastOneGood =
    Boolean(data.dns_on_router) ||
    Boolean(data.dhcp_config_status) ||
    Boolean(data.bootstrap_dns_status) ||
    Boolean(data.dns_status);

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  const subscriptionItems: IDiagnosticsChecksItem[] = [];
  if (userinfoResult.success && Array.isArray(userinfoResult.data)) {
    const now = Math.floor(Date.now() / 1000);
    for (const sub of userinfoResult.data) {
      if (sub.expire > 0) {
        const daysLeft = Math.floor((sub.expire - now) / 86400);
        const expState: IDiagnosticsChecksItem['state'] =
          daysLeft < 0 ? 'error' : daysLeft < 7 ? 'warning' : 'success';
        const label =
          daysLeft < 0
            ? _('Expired')
            : daysLeft === 0
              ? _('Expires today')
              : `${daysLeft}d`;
        subscriptionItems.push({
          state: expState,
          key: `${_('Subscription')} [${sub.section}] ${_('expires')}`,
          value: `${formatExpiry(sub.expire)} (${label})`,
        });
      } else {
        subscriptionItems.push({
          state: 'success',
          key: `${_('Subscription')} [${sub.section}] ${_('expires')}`,
          value: `∞`,
        });
      }
      if (sub.total > 0) {
        const used = sub.upload + sub.download;
        const pct = Math.min(100, Math.round((used / sub.total) * 100));
        const trafficState: IDiagnosticsChecksItem['state'] =
          pct >= 90 ? 'warning' : 'success';
        subscriptionItems.push({
          state: trafficState,
          key: `${_('Subscription')} [${sub.section}] ${_('traffic')}`,
          value: `${formatBytes(used)} / ${formatBytes(sub.total)} (${pct}%)`,
        });
      } else if (sub.download > 0) {
        subscriptionItems.push({
          state: 'success',
          key: `${_('Subscription')} [${sub.section}] ${_('traffic')}`,
          value: `↓ ${formatBytes(sub.download)}`,
        });
      }
    }
  }

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      ...insertIf<IDiagnosticsChecksItem>(
        data.dns_type === 'doh' ||
          data.dns_type === 'dot' ||
          !data.bootstrap_dns_status,
        [
          {
            state: data.bootstrap_dns_status ? 'success' : 'error',
            key: _('Bootsrap DNS'),
            value: data.bootstrap_dns_server,
          },
        ],
      ),
      {
        state: data.dns_status ? 'success' : 'error',
        key: _('Main DNS'),
        value: `${data.dns_server} [${data.dns_type}]`,
      },
      {
        state: data.dns_on_router ? 'success' : 'error',
        key: _('DNS on router'),
        value: '',
      },
      {
        state: data.dhcp_config_status ? 'success' : 'error',
        key: _('DHCP has DNS server'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(Boolean(data.dns_intercepted), [
        {
          state: 'warning',
          key: _('Port 53 is intercepted by the provider'),
          value: _('Plain DNS answers cannot be trusted, use DoH or DoT'),
        },
      ]),
      ...insertIf<IDiagnosticsChecksItem>(Boolean(data.dns_failover_active), [
        {
          state: 'warning',
          key: _('DNS Failover active'),
          value: `${data.dns_failover_original_type}/${data.dns_failover_original_server} → ${data.dns_server} [${data.dns_type}]`,
        },
      ]),
      ...subscriptionItems,
    ],
  });

  if (!atLeastOneGood) {
    throw new Error('DNS checks failed');
  }
}
