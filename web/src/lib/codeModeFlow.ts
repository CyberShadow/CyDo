import type { Node } from "web-tree-sitter";
import type {
  FlowDocument,
  FlowSink,
  FlowSource,
  FlowValue,
} from "./contentFlow";
import {
  decodeJavaScriptLiteral,
  decodeJavaScriptUnicodeEscape,
} from "./javascriptLiteral";

type BindingIndex = ReadonlyMap<string, readonly Node[]>;
type LiteralConstruct = "string-literal" | "template-literal" | "string-raw";

type Operand = {
  literal: Node;
  construct: LiteralConstruct;
  binding: "inline" | "const";
};

function atField(parent: Node, field: string, node: Node): boolean {
  return parent.childForFieldName(field)?.id === node.id;
}

function bindingChildren(
  node: Node,
  binding: boolean,
): number | true | undefined {
  switch (node.type) {
    case "object_pattern":
    case "array_pattern":
    case "rest_pattern":
      return binding ? true : undefined;
    case "pair_pattern":
      return binding ? node.childForFieldName("value")?.id : undefined;
    case "assignment_pattern":
    case "object_assignment_pattern":
      return binding ? node.childForFieldName("left")?.id : undefined;
    case "variable_declarator":
    case "function_declaration":
    case "generator_function_declaration":
    case "function_expression":
    case "generator_function":
    case "class_declaration":
    case "class":
      return node.childForFieldName("name")?.id;
    case "formal_parameters":
    case "namespace_import":
    case "import_clause":
      return true;
    case "import_specifier":
      return (node.childForFieldName("alias") ?? node.childForFieldName("name"))
        ?.id;
    case "arrow_function":
    case "catch_clause":
      return node.childForFieldName("parameter")?.id;
    case "for_in_statement":
      return node.childForFieldName("kind")
        ? node.childForFieldName("left")?.id
        : undefined;
    default:
      return undefined;
  }
}

type ConstInitializer = { node: Node; declarationEnd: number };

const identifierStart = /^[$_\p{ID_Start}]$/u;
const identifierContinue = /^[$\u200c\u200d\p{ID_Continue}]$/u;

function identifierName(node: Node): string | null {
  const raw = node.text;
  if (!raw.includes("\\")) return raw;
  let name = "";
  let cursor = 0;
  for (const match of raw.matchAll(
    /\\(?:u(?:\{[\da-fA-F]+\}|[\da-fA-F]{4}))?/g,
  )) {
    const index = match.index;
    const escape = match[0];
    const decoded = decodeJavaScriptUnicodeEscape(escape.slice(1));
    // Validate before adjoining escapes can combine into a surrogate pair.
    const valid = index === 0 ? identifierStart : identifierContinue;
    if (decoded === null || !valid.test(decoded)) return null;
    name += raw.slice(cursor, index) + decoded;
    cursor = index + escape.length;
  }
  return name + raw.slice(cursor);
}

function isIdentifierReference(node: Node): boolean {
  return node.type === "identifier" || node.type === "undefined";
}

function indexCell(
  root: Node,
  bindings: Map<string, Node[]>,
  calls: Node[],
  initializers: Map<number, ConstInitializer>,
): void {
  const pending = [
    { node: root, inError: false, binding: false, topLevel: false },
  ];
  while (pending.length > 0) {
    const { node, inError, binding, topLevel } = pending.pop()!;
    const recovered = inError || node.type === "ERROR";
    if (
      node.type === "shorthand_property_identifier_pattern" ||
      (isIdentifierReference(node) && (recovered || binding))
    ) {
      const name = identifierName(node);
      if (name !== null) {
        const sites = bindings.get(name);
        if (sites === undefined) bindings.set(name, [node]);
        else sites.push(node);
      }
    }
    if (node.type === "call_expression" && !node.hasError) calls.push(node);
    const children = node.namedChildren;
    if (
      topLevel &&
      node.type === "lexical_declaration" &&
      !node.hasError &&
      node.childForFieldName("kind")?.type === "const"
    ) {
      for (const declarator of children) {
        if (declarator.type !== "variable_declarator") continue;
        const name = declarator.childForFieldName("name");
        const value = declarator.childForFieldName("value");
        if (name?.type === "identifier" && value)
          initializers.set(name.id, {
            node: value,
            declarationEnd: declarator.endIndex,
          });
      }
    }
    const binds = bindingChildren(node, binding);
    for (let index = children.length - 1; index >= 0; index--) {
      const child = children[index]!;
      pending.push({
        node: child,
        inError: recovered,
        binding: binds === true || binds === child.id,
        topLevel: node.id === root.id,
      });
    }
  }
}

function syntaxChildren(node: Node): Node[] {
  return node.children.filter((child) => child.type !== "comment");
}

function listItems(node: Node, open: string, close: string): Node[] | null {
  const children = syntaxChildren(node);
  if (children[0]?.type !== open || children.at(-1)?.type !== close)
    return null;
  const items: Node[] = [];
  for (let index = 1; index < children.length - 1; index++) {
    const child = children[index]!;
    if (index % 2 === 0) {
      if (child.type !== ",") return null;
    } else {
      if (!child.isNamed) return null;
      items.push(child);
    }
  }
  return items;
}

function callParts(node: Node): [Node, Node] | null {
  const children = syntaxChildren(node);
  const callee = node.childForFieldName("function");
  const args = node.childForFieldName("arguments");
  return children.length === 2 &&
    callee &&
    args &&
    callee.id === children[0]!.id &&
    args.id === children[1]!.id
    ? [callee, args]
    : null;
}

function memberName(node: Node | null, receiver: string): string | null {
  if (node?.type !== "member_expression") return null;
  const children = syntaxChildren(node);
  const object = node.childForFieldName("object");
  const property = node.childForFieldName("property");
  if (
    children.length !== 3 ||
    children[1]?.type !== "." ||
    object?.type !== "identifier" ||
    identifierName(object) !== receiver ||
    property?.type !== "property_identifier"
  )
    return null;
  return identifierName(property);
}

function resolveLiteral(
  node: Node,
  bindings: BindingIndex,
  binding: Operand["binding"],
): Operand | null {
  let literal = node;
  let construct: LiteralConstruct;
  if (node.type === "string") {
    construct = "string-literal";
  } else {
    if (node.type === "template_string") {
      construct = "template-literal";
    } else {
      if (node.type !== "call_expression" || bindings.has("String"))
        return null;
      const parts = callParts(node);
      if (
        !parts ||
        memberName(parts[0], "String") !== "raw" ||
        parts[1].type !== "template_string"
      )
        return null;
      const template = parts[1];
      construct = "string-raw";
      literal = template;
    }
  }
  return { literal, construct, binding };
}

function operandInitializer(
  node: Node,
  use: Node,
  bindings: BindingIndex,
  initializers: ReadonlyMap<number, ConstInitializer>,
): { node: Node; binding: Operand["binding"] } | null {
  if (
    !isIdentifierReference(node) &&
    node.type !== "shorthand_property_identifier"
  )
    return { node, binding: "inline" };
  const name = identifierName(node);
  if (name === null) return null;
  const sites = bindings.get(name);
  if (sites?.length !== 1) return null;
  const initializer = initializers.get(sites[0]!.id);
  return initializer && initializer.declarationEnd < use.startIndex
    ? { node: initializer.node, binding: "const" }
    : null;
}

const moduleReservedWords = new Set([
  "await",
  "break",
  "case",
  "catch",
  "class",
  "const",
  "continue",
  "debugger",
  "default",
  "delete",
  "do",
  "else",
  "enum",
  "export",
  "extends",
  "false",
  "finally",
  "for",
  "function",
  "if",
  "implements",
  "import",
  "in",
  "instanceof",
  "interface",
  "let",
  "new",
  "null",
  "package",
  "private",
  "protected",
  "public",
  "return",
  "static",
  "super",
  "switch",
  "this",
  "throw",
  "true",
  "try",
  "typeof",
  "var",
  "void",
  "while",
  "with",
  "yield",
]);

function execCommandOperand(options: Node): Node | null {
  if (options.type !== "object") return null;
  let command: Node | null = null;
  let count = 0;
  let prototypeSetter = false;
  const properties = listItems(options, "{", "}");
  if (!properties) return null;
  for (const property of properties) {
    if (property.type === "shorthand_property_identifier") {
      const name = identifierName(property);
      if (name === null || moduleReservedWords.has(name)) return null;
      if (name === "cmd") {
        count++;
        command = property;
      }
      continue;
    }
    if (property.type !== "pair") return null;
    const key = property.childForFieldName("key");
    if (!key) return null;
    const children = syntaxChildren(property);
    if (
      children.length !== 3 ||
      children[0]!.id !== key.id ||
      children[1]!.type !== ":" ||
      !atField(property, "value", children[2]!)
    )
      return null;
    let name: string | null;
    switch (key.type) {
      case "property_identifier":
        name = identifierName(key);
        if (name === null) return null;
        break;
      case "string": {
        const decoded = decodeJavaScriptLiteral(key, "cooked");
        if (decoded === null) return null;
        name = decoded.text;
        break;
      }
      case "number":
        if (/^0[0-9_]/.test(key.text)) return null;
        continue;
      default:
        return null;
    }
    if (name === "__proto__") {
      if (prototypeSetter) return null;
      prototypeSetter = true;
    }
    if (name === "cmd") {
      count++;
      command = children[2]!;
    }
  }
  return count === 1 ? command : null;
}

export function analyzeCodeModeCell(root: Node, source: string): FlowDocument {
  const bindings = new Map<string, Node[]>();
  const calls: Node[] = [];
  const initializers = new Map<number, ConstInitializer>();
  indexCell(root, bindings, calls, initializers);
  const groups = new Map<
    number,
    {
      operand: Operand;
      value: FlowValue;
      sinks: FlowSink[];
    } | null
  >();
  if (!bindings.has("tools")) {
    for (const call of calls) {
      const parts = callParts(call);
      if (!parts) continue;
      const [callee, args] = parts;
      if (memberName(callee, "tools") !== "exec_command") continue;
      if (args.type !== "arguments") continue;
      const argumentsList = listItems(args, "(", ")");
      if (argumentsList?.length !== 1) continue;
      const input = execCommandOperand(argumentsList[0]!);
      if (input === null) continue;
      const initializer = operandInitializer(
        input,
        call,
        bindings,
        initializers,
      );
      if (initializer === null) continue;
      const sink = {
        kind: "program",
        language: "bash",
        channel: "argv",
      } as const;
      const id = initializer.node.id;
      let group = groups.get(id);
      if (group === undefined) {
        const operand = resolveLiteral(
          initializer.node,
          bindings,
          initializer.binding,
        );
        const value =
          operand &&
          decodeJavaScriptLiteral(
            operand.literal,
            operand.construct === "string-raw" ? "raw" : "cooked",
          );
        group =
          operand && value && value.text.length > 0
            ? { operand, value, sinks: [] }
            : null;
        groups.set(id, group);
      }
      group?.sinks.push(sink);
    }
  }
  const sources = [...groups.values()]
    .filter((group) => group !== null)
    .map(
      ({ operand, value, sinks }): FlowSource => ({
        span: {
          start: operand.literal.startIndex + 1,
          end: operand.literal.endIndex - 1,
        },
        value,
        sinks,
        origin: {
          language: "javascript",
          construct: operand.construct,
          attributes: { binding: operand.binding },
        },
        layout: "inline",
        child: null,
      }),
    );
  return { language: "javascript", text: source, sources };
}
