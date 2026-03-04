import { h } from "preact";
import type { SessionState } from "../types";
import { SystemBanner } from "./SystemBanner";
import { MessageList } from "./MessageList";
import { InputBox } from "./InputBox";

interface Props {
  session: SessionState;
  connected: boolean;
  onSend: (text: string) => void;
  onInterrupt: () => void;
  onResume: () => void;
}

export function SessionView({ session, connected, onSend, onInterrupt, onResume }: Props) {
  return (
    <>
      <SystemBanner
        sessionInfo={session.sessionInfo}
        connected={connected}
        totalCost={session.totalCost}
        isProcessing={session.isProcessing}
      />
      <MessageList
        sessionId={session.sid}
        messages={session.messages}
        streamingBlocks={session.streamingBlocks}
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
        />
      )}
    </>
  );
}
