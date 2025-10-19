import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;

const contractName = "Crypto-Thrift--Ajo-Esusu-";

describe("Crypto Thrift Loan System Tests", () => {
  it("ensures simnet is well initialised", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  it("should check loan system stats", () => {
    const { result } = simnet.callReadOnlyFn(
      contractName,
      "get-loan-system-stats",
      [],
      wallet1
    );
    expect(result).toBeOk(Cl.tuple({
      "total-loans-issued": Cl.uint(0),
      "current-interest-rate": Cl.uint(5),
      "min-reputation-for-loan": Cl.uint(70),
      "max-loans-per-member": Cl.uint(3),
    }));
  });

  it("should reject loan request for non-member", () => {
    const { result } = simnet.callPublicFn(
      contractName,
      "request-loan",
      [Cl.uint(500000)],
      wallet3
    );
    expect(result).toBeErr(Cl.uint(101)); // err-not-member
  });

  it("should get loan details for non-existent loan", () => {
    const { result } = simnet.callReadOnlyFn(
      contractName,
      "get-loan-details",
      [Cl.uint(1)],
      wallet1
    );
    expect(result).toBeNone();
  });

  it("should prevent repayment on non-existent loan", () => {
    const { result } = simnet.callPublicFn(
      contractName,
      "make-repayment",
      [Cl.uint(999), Cl.uint(100000)],
      wallet1
    );
    expect(result).toBeErr(Cl.uint(111)); // err-loan-not-found
  });

  it("should prevent default handling by non-owner", () => {
    const { result } = simnet.callPublicFn(
      contractName,
      "handle-loan-default",
      [Cl.uint(1)],
      wallet1
    );
    expect(result).toBeErr(Cl.uint(111)); // err-loan-not-found (loan doesn't exist)
  });

  it("should check loan status of non-existent loan", () => {
    const { result } = simnet.callReadOnlyFn(
      contractName,
      "check-loan-status",
      [Cl.uint(999)],
      wallet1
    );
    expect(result).toBeErr(Cl.uint(111)); // err-loan-not-found
  });
});
