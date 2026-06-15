import { executeShellCommand } from '../../../helpers';
import { Podkop } from '../../types';

export async function callBaseMethod<T>(
  method: Podkop.AvailableMethods,
  args: string[] = [],
  command: string = '/usr/bin/podkop',
  timeoutMs: number = 15000,
): Promise<Podkop.MethodResponse<T>> {
  const response = await executeShellCommand({
    command,
    args: [method as string, ...args],
    timeout: timeoutMs,
  });

  if (response.stdout) {
    try {
      return {
        success: true,
        data: JSON.parse(response.stdout) as T,
      };
    } catch (_e) {
      return {
        success: true,
        data: response.stdout as T,
      };
    }
  }

  // Commands like subscription_update log via syslog and print nothing to
  // stdout on success, so fall back to the process exit code.
  if (response.code === 0) {
    return {
      success: true,
      data: response.stdout as T,
    };
  }

  return {
    success: false,
    error: response.stderr || '',
  };
}
