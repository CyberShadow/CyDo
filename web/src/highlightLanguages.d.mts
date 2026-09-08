export declare const EXT_TO_LANG: Readonly<Record<string, string>>;
export declare const FILENAME_TO_LANG: Readonly<Record<string, string>>;
export declare const supportedHighlightLanguages: readonly string[];

export declare function langFromPath(filePath: string): string | null;
