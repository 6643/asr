import { expect, test } from "bun:test";
import fs from "fs";
import path from "node:path";
import ts from "typescript";

const PROJECT_SOURCE_PATHS = [
    path.resolve(process.cwd(), "index.ts"),
    path.resolve(process.cwd(), "src"),
    path.resolve(process.cwd(), "scripts"),
];

const collectSourceFiles = (dir: string): string[] => {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    return entries.flatMap((entry) => {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) return collectSourceFiles(fullPath);
        if (!entry.isFile()) return [];
        if (!entry.name.endsWith(".ts")) return [];
        return [fullPath];
    });
};

const collectProjectSourceFiles = (filePath: string): string[] => {
    if (!fs.existsSync(filePath)) return [];
    if (fs.statSync(filePath).isDirectory()) return collectSourceFiles(filePath);
    if (!filePath.endsWith(".ts")) return [];
    return [filePath];
};

const isFunctionBoundary = (node: ts.Node): boolean => {
    return ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node);
};

const isControlNode = (node: ts.Node): boolean => {
    return (
        ts.isIfStatement(node) ||
        ts.isForStatement(node) ||
        ts.isForInStatement(node) ||
        ts.isForOfStatement(node) ||
        ts.isWhileStatement(node) ||
        ts.isDoStatement(node) ||
        ts.isSwitchStatement(node) ||
        ts.isTryStatement(node)
    );
};

const formatLocation = (sourceFile: ts.SourceFile, node: ts.Node): string => {
    const pos = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
    return `${path.relative(process.cwd(), sourceFile.fileName)}:${pos.line + 1}:${pos.character + 1}`;
};

const findNestedControlViolations = (filePath: string): string[] => {
    const source = fs.readFileSync(filePath, "utf8");
    const sourceFile = ts.createSourceFile(filePath, source, ts.ScriptTarget.Latest, true);
    const violations: string[] = [];

    const visit = (node: ts.Node, depth: number): void => {
        const currentDepth = isFunctionBoundary(node) && node !== sourceFile ? 0 : depth;
        const nextDepth = isControlNode(node) ? currentDepth + 1 : currentDepth;
        if (nextDepth > 1) {
            violations.push(formatLocation(sourceFile, node));
            return;
        }
        ts.forEachChild(node, (child) => visit(child, nextDepth));
    };

    visit(sourceFile, 0);
    return violations;
};

test("project TypeScript keeps control nesting depth at one level", () => {
    const violations = PROJECT_SOURCE_PATHS.flatMap(collectProjectSourceFiles).flatMap(findNestedControlViolations);
    expect(violations).toEqual([]);
});
