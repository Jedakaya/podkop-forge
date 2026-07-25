import { COMMAND_TIMEOUT } from '../constants';
import { withTimeout } from './withTimeout';

interface ExecuteShellCommandParams {
  command: string;
  args: string[];
  timeout?: number;
}

interface ExecuteShellCommandResponse {
  stdout: string;
  stderr: string;
  code?: number;
}

export async function executeShellCommand({
  command,
  args,
  timeout = COMMAND_TIMEOUT,
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  try {
    // Must be awaited inside the try: returning the promise unawaited lets a
    // timeout rejection escape this catch and stall callers stuck in a
    // "loading" state forever.
    return await withTimeout(
      fs.exec(command, args),
      timeout,
      [command, ...args].join(' '),
    );
  } catch (err) {
    const error = err as Error;

    return { stdout: '', stderr: error?.message, code: undefined };
  }
}
