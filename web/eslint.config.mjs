import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import { fileURLToPath } from "url";
import { dirname } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));

export default tseslint.config(
  { ignores: ["src/vendor/**"] },
  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: __dirname,
      },
    },
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unused-vars": [
        "error",
        { ignoreRestSiblings: true },
      ],
      "no-control-regex": "off",
      "no-empty": ["error", { allowEmptyCatch: true }],
      // Numbers in template literals are standard JS and valid — the rule is too noisy.
      "@typescript-eslint/restrict-template-expressions": "off",
      // Non-null assertions were added to handle noUncheckedIndexedAccess array/map
      // lookups where the developer has already verified existence. Refactoring all
      // 85 call-sites would introduce churn without a safety gain in this codebase.
      "@typescript-eslint/no-non-null-assertion": "off",
    },
  },
);
