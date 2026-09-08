import { shikiLanguages, shikiRoots } from "virtual:cydo-export-cdn";
import { importModuleWithFallback } from "./cdnLoader";

export type ThemedToken = { content: string; color?: string };
export type BundledLanguage = string;
export type Highlighter = never;

type ShikiHighlighter = {
  loadLanguage(...languages: unknown[]): Promise<unknown>;
};

type ShikiModule = {
  bundledLanguages: Record<string, unknown>;
  createHighlighter(...args: unknown[]): Promise<ShikiHighlighter>;
};

type LanguageModule = {
  default: unknown;
};

function selectedHost(candidate: (typeof shikiRoots)[number]) {
  const index = shikiRoots.indexOf(candidate);
  if (index === -1) throw new Error("selected Shiki root is not generated");
  return index === 0 ? "jsdelivr" : "unpkg";
}

export async function createHighlighter(...args: unknown[]): Promise<never> {
  const selected = await importModuleWithFallback<ShikiModule>(
    "shiki-root",
    shikiRoots,
  );
  const host = selectedHost(selected.candidate);
  const highlighter = await selected.module.createHighlighter(...args);
  const originalLoadLanguage = highlighter.loadLanguage.bind(highlighter);

  highlighter.loadLanguage = async (...languages) => {
    for (const language of languages) {
      if (
        typeof language === "string" &&
        !Object.hasOwn(selected.module.bundledLanguages, language) &&
        !Object.hasOwn(shikiLanguages, language)
      ) {
        throw new Error(`unknown Shiki language ${language}`);
      }
    }

    const registrations = await Promise.all(
      languages.map(async (language) => {
        if (
          typeof language !== "string" ||
          Object.hasOwn(selected.module.bundledLanguages, language)
        ) {
          return language;
        }

        const candidate = shikiLanguages[language]![host];
        const loaded = await importModuleWithFallback<LanguageModule>(
          `shiki-language:${host}:${language}`,
          [candidate],
        );
        return loaded.module.default;
      }),
    );

    return originalLoadLanguage(...registrations);
  };

  return highlighter as never;
}
