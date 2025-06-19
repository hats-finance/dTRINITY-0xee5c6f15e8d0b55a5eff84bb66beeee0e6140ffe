// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Issuer} from "../contracts/dstable/Issuer.sol";
import {IPriceOracleGetter} from "../contracts/common/IAaveOracle.sol"; 
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDstable is ERC20 {
    constructor(string memory name, string memory symbol)
        ERC20(name, symbol)
    {
    }
}


contract CounterTest is Test {
    Issuer public issuer;
    MockDstable dstable;
    address public _collateralVault = address(0x1);

    bytes32 public constant AMO_MANAGER_ROLE = keccak256("AMO_MANAGER_ROLE");
    address public _amoManagerA = makeAddr("AMO_MANAGER_A");
    address public _amoManagerB = makeAddr("AMO_MANAGER_B");



    function setUp() public {
        dstable = new MockDstable("DSTABLE","DSTABLE");
        address _dstable = address(dstable);
        IPriceOracleGetter oracle = IPriceOracleGetter(address(0x3)); //random data as this is just for testing.
        
        issuer = new Issuer(_collateralVault,_dstable,oracle,_amoManagerA);
    }


    function test_AmoManagerRoleRevocationProblem() public {
        issuer.setAmoManager(_amoManagerA);
        issuer.hasRole(AMO_MANAGER_ROLE,address(_amoManagerA));

        //Now owner wanna change _amoManagerA -> _amoManagerB

        issuer.setAmoManager(_amoManagerB);
        assertEq(issuer.hasRole(AMO_MANAGER_ROLE,address(_amoManagerA)), true); //Notice that _amoManagerA still holds AMO_MANAGER_ROLE role. 
        
    }

}
