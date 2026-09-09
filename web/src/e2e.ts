export {};

declare global {
  interface Window {
    __cydoE2e?: {
      fork?: (tid: number, anchor: string) => void;
      undo?: (
        tid: number,
        anchor: string,
        dryRun: boolean,
        revertConversation: boolean,
        revertFiles: boolean,
      ) => void;
    };
  }
}
