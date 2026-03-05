import { h } from "preact";
import type { SessionState } from "../types";
import type { Theme } from "../useTheme";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";

interface Props {
  session: SessionState;
  connected: boolean;
  onSend: (text: string) => void;
  onInterrupt: () => void;
  onResume: () => void;
  theme: Theme;
  onToggleTheme: () => void;
}

export function SessionView({
  session,
  connected,
  onSend,
  onInterrupt,
  onResume,
  theme,
  onToggleTheme,
}: Props) {
  if (!session.historyLoaded) {
    return (
      <div class="session-loading">
        <span>Loading session…</span>
      </div>
    );
  }

  return (
    <>
      <SystemBanner
        sessionInfo={session.sessionInfo}
        connected={connected}
        totalCost={session.totalCost}
        isProcessing={session.isProcessing}
        theme={theme}
        onToggleTheme={onToggleTheme}
      />
      <MessageList
        sessionId={session.sid}
        messages={session.messages}
        isProcessing={session.isProcessing}
      />
      {session.resumable ? (
        <div class="resume-bar">
          <button class="btn btn-resume" onClick={onResume}>
            Resume Session
          </button>
        </div>
      ) : (
        <InputBox
          onSend={onSend}
          onInterrupt={onInterrupt}
          isProcessing={session.isProcessing}
          disabled={!connected}
          sessionId={session.sid}
          preReloadDrafts={session.preReloadDrafts}
        />
      )}
    </>
  );
}
